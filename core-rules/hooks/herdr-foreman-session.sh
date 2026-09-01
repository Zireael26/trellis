#!/usr/bin/env bash
# SessionStart: when running inside Herdr, resolve OMP role chains from live quota
# and inject them so Claude auto-adopts the herdr-foreman skill for multi-unit work.
[ "${HERDR_ENV:-}" = 1 ] || exit 0
if [ -z "${HERDR_WORKSPACE_ID:-}" ] || [ -z "${HERDR_PANE_ID:-}" ]; then
  echo "DEGRADED: inside Herdr but the current workspace or pane identity is unavailable; deciding OMP roles were not resolved. Do not substitute silently."
  exit 0
fi
command -v omp >/dev/null 2>&1 || { echo "DEGRADED: inside Herdr but omp is not on PATH; foreman and resolver roles are unavailable. Do not substitute silently."; exit 0; }

# Claude gives this hook 60 seconds. Resolver internals have defensive longer
# limits, so each pass gets a 20-second outer wall-clock cap that kills the
# pass's whole process group and cannot consume the SessionStart budget.
RESOLVER_PASS_TIMEOUT=20
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
# when a minimal SessionStart environment has no HOME; otherwise keep OMP state
# in the normal user HOME, not in Trellis' machine-state directory.
STATE_HOME="${HOME:-${TRELLIS_HOME:-}}"
if [ -z "$STATE_HOME" ]; then
  echo "DEGRADED: no HOME or TRELLIS_HOME for resolver state; implementer and deciding review roles were not resolved. Select an implementer and run the resolver manually; do not substitute silently."
  exit 0
fi
HOME="$STATE_HOME"
export HOME
STATE_PARENT="$STATE_HOME/.omp/agent"
if ! (umask 077 && mkdir -p "$STATE_PARENT") 2>/dev/null ||
   ! chmod 700 "$STATE_HOME/.omp" "$STATE_PARENT" 2>/dev/null; then
  echo "DEGRADED: could not create a private resolver state parent at $STATE_PARENT; implementer and deciding review roles were not resolved. Do not substitute silently."
  exit 0
fi
ROLE_STATE="$STATE_PARENT/roles-resolved.json"
clear_role_state() {
  if [ -e "$ROLE_STATE" ] || [ -L "$ROLE_STATE" ]; then
    rm -f "$ROLE_STATE"
  fi
}
# A timed-out deciding pass must not leave a previous roster available for a
# foreman to mistake for this session's cross-family decision.
if ! clear_role_state; then
  echo "DEGRADED: could not clear stale resolver state at $ROLE_STATE; implementer and deciding review roles were not resolved. Do not substitute silently."
  exit 0
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

FOREMEN_RAW="$(run_with_timeout 5 herdr agent list 2>/dev/null)"
if [ "$?" -eq 0 ]; then
  FOREMEN="$(printf '%s\n' "$FOREMEN_RAW" | python3 -c '
import json,sys
try:
    a=[x for x in json.load(sys.stdin)["result"]["agents"] if x["agent"]=="omp"]
    print(", ".join("%s(%s,%s)" % (x["pane_id"], x["agent_status"], x["cwd"].rsplit("/",1)[-1]) for x in a) or "none")
except Exception:
    print("unknown")')"
else
  FOREMEN="unknown"
fi
echo "## herdr-foreman (auto)"
echo "Inside Herdr (pane ${HERDR_PANE_ID:-?}, workspace ${HERDR_WORKSPACE_ID:-?}). For any multi-unit task, follow skill \`herdr-foreman\`: Claude = apex (briefs, git, receipts), OMP foreman pane = eval driver, workers chosen by quota. Existing OMP panes: ${FOREMEN}"

# Two passes: the first is discovery-only and learns the resolved implementer.
# The deciding pass supplies that exact identity, then both the resolver and
# this writer require its live implementer row to remain unchanged before any
# cross-family reviewer artifact can survive.
DISCOVERY_JSON="$(HOME="$STATE_HOME" run_with_timeout "$RESOLVER_PASS_TIMEOUT" python3 "$R" --json)"
DISCOVERY_STATUS="$?"
if [ "$DISCOVERY_STATUS" -eq 142 ]; then
  clear_role_state
  echo "DEGRADED: resolver discovery timed out after ${RESOLVER_PASS_TIMEOUT}s; implementer, reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Select an implementer, then run $R --implementer <agent> manually; do not substitute silently."
  exit 0
fi
if [ "$DISCOVERY_STATUS" -ne 0 ]; then
  clear_role_state
  echo "DEGRADED: resolver discovery failed (exit $DISCOVERY_STATUS); implementer, reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Select an implementer, then run $R --implementer <agent> manually; do not substitute silently."
  exit 0
fi
IMPL="$(printf '%s\n' "$DISCOVERY_JSON" | python3 -c 'import json,sys
try:
    c = json.load(sys.stdin)["roles"]["implementer"]["chosen"]
    if not c or not c.get("agent"):
        raise ValueError("no implementer")
    print(c["agent"])
except Exception:
    sys.exit(1)' 2>/dev/null)"
if [ "$?" -ne 0 ] || [ -z "$IMPL" ]; then
  clear_role_state
  echo "DEGRADED: no implementer resolved; reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Select an implementer, then run $R --implementer <agent> manually; do not substitute silently."
  exit 0
fi

# Do not leave the discovery-only roster visible while the deciding pass runs.
if ! clear_role_state; then
  echo "DEGRADED: could not clear discovery-only resolver state at $ROLE_STATE; reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Do not substitute silently."
  exit 0
fi

# Bind the artifact to this exact pass. Existence or an ISO timestamp alone is
# not freshness: a concurrent/global writer can recreate the pathname. The
# workspace/pane are recorded separately in the scoped artifact; consumers do
# exact field comparisons, never a nonce-prefix approximation.
ROLE_RESOLUTION_NONCE="${HERDR_WORKSPACE_ID}:${HERDR_PANE_ID}:$$:${RANDOM}"
HERDR_RESOLUTION_NONCE="$ROLE_RESOLUTION_NONCE" \
  HOME="$STATE_HOME" \
  run_with_timeout "$RESOLVER_PASS_TIMEOUT" \
  python3 "$R" --implementer "$IMPL"
DECIDING_STATUS="$?"
if [ "$DECIDING_STATUS" -eq 142 ]; then
  clear_role_state
  echo "DEGRADED: deciding resolver pass timed out after ${RESOLVER_PASS_TIMEOUT}s for implementer $IMPL; reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Do not substitute silently."
elif [ "$DECIDING_STATUS" -ne 0 ]; then
  clear_role_state
  echo "DEGRADED: deciding resolver pass failed (exit $DECIDING_STATUS) for implementer $IMPL; reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Do not substitute silently."
else
  if ! python3 - "$ROLE_STATE" "$POLICY" "$IMPL" "$ROLE_RESOLUTION_NONCE" \
      "$HERDR_WORKSPACE_ID" "$HERDR_PANE_ID" <<'PY'
import hashlib
import json
import math
import os
import stat
import sys

path, policy_path, implementer, nonce, workspace, pane = sys.argv[1:]


def nonempty(value):
    return (
        isinstance(value, str)
        and bool(value)
        and value.strip() == value
        and "\x00" not in value
    )


def catalog_identity(cfg, agent):
    agents = cfg.get("agents")
    if not isinstance(agents, dict) or not nonempty(agent):
        return None
    facts = agents.get(agent)
    if not isinstance(facts, dict):
        return None
    identity = (agent, facts.get("model"), facts.get("provider"))
    family = facts.get("family")
    if not all(nonempty(value) for value in identity) or not nonempty(family):
        return None
    return identity


def agent_family(cfg, agent):
    agents = cfg.get("agents")
    if not isinstance(agents, dict) or not nonempty(agent):
        return None
    facts = agents.get(agent)
    if not isinstance(facts, dict):
        return None
    family = facts.get("family")
    return family if nonempty(family) else None


def policy_identity(cfg, agent):
    identity = catalog_identity(cfg, agent)
    if identity is None:
        raise ValueError("implementer has no unambiguous policy identity")
    return identity


def policy_candidate(cfg, role, entry):
    if not isinstance(entry, dict):
        return False
    agent = entry.get("agent")
    spec = (cfg.get("roles") or {}).get(role)
    chain = spec.get("chain") if isinstance(spec, dict) else None
    identity = catalog_identity(cfg, agent)
    return (
        identity is not None
        and isinstance(chain, list)
        and any(
            isinstance(candidate, dict) and candidate.get("agent") == agent
            for candidate in chain
        )
        and entry.get("model") == identity[1]
        and entry.get("provider") == identity[2]
    )


CANDIDATE_FIELDS = ("agent", "model", "provider", "remaining", "note")
VERDICT_ROLES = {"reviewer", "security_reviewer", "merge_reviewer", "refuter"}
SINGLE_VERDICT_ROLES = ("reviewer", "security_reviewer", "merge_reviewer")


def fields_match(left, right):
    return all(left.get(key) == right.get(key) for key in CANDIDATE_FIELDS)


try:
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("artifact is not a regular file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_IMODE(opened.st_mode) != 0o600
            or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
        ):
            raise ValueError("artifact identity or mode changed")
        with os.fdopen(descriptor, encoding="utf-8") as source:
            descriptor = None
            artifact = json.load(source)
    finally:
        if descriptor is not None:
            os.close(descriptor)

    with open(policy_path, "rb") as source:
        policy_bytes = source.read()
    cfg = json.loads(policy_bytes)
    ttl = cfg.get("cache_ttl_seconds", 600)
    if (
        isinstance(ttl, bool)
        or not isinstance(ttl, (int, float))
        or not math.isfinite(ttl)
        or ttl <= 0
    ):
        raise ValueError("policy TTL is invalid")
    if not isinstance(artifact, dict):
        raise ValueError("artifact root is not an object")
    if artifact.get("roles_policy") != {
        "roles_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "cache_ttl_seconds": ttl,
    }:
        raise ValueError("artifact does not bind the active release policy")
    if not isinstance(cfg.get("agents"), dict) or not isinstance(cfg.get("roles"), dict):
        raise ValueError("policy catalog is not an object")
    implementer_family = agent_family(cfg, implementer)
    agent, model, provider = policy_identity(cfg, implementer)
    role_specs = cfg["roles"]
    families = {}
    for name in cfg["agents"]:
        family = agent_family(cfg, name)
        if family is None:
            raise ValueError("policy family map is incomplete")
        families[name] = family
    scope = artifact["resolution_scope"]
    scope_keys = {
        "scoped",
        "implementer",
        "implementer_model",
        "implementer_provider",
        "implementer_family",
        "cross_family_enforced",
        "verdict_families_distinct",
        "herdr_workspace_id",
        "herdr_pane_id",
    }
    if (
        not isinstance(scope, dict)
        or set(scope) != scope_keys
        or scope.get("scoped") is not True
        or scope.get("cross_family_enforced") is not True
        or not isinstance(scope.get("verdict_families_distinct"), bool)
        or scope.get("implementer") != implementer
        or scope.get("implementer_model") != model
        or scope.get("implementer_provider") != provider
        or scope.get("implementer_family") != implementer_family
        or scope.get("herdr_workspace_id") != workspace
        or scope.get("herdr_pane_id") != pane
    ):
        raise ValueError("artifact scope is not this deciding Herdr pass")
    if artifact["resolution_nonce"] != nonce:
        raise ValueError("artifact nonce does not match deciding pass")
    if artifact["family_collapse"] != []:
        raise ValueError("artifact reports family collapse")
    roles = artifact["roles"]
    if not isinstance(roles, dict) or set(roles) != set(role_specs):
        raise ValueError("artifact roles do not match the policy roster")
    derived_degraded = []
    for role in role_specs:
        resolved = roles[role]
        if not isinstance(resolved, dict):
            raise ValueError("resolved role is not an object")
        trail = resolved["trail"]
        refusals = resolved["refusals"]
        if not isinstance(trail, list) or not isinstance(refusals, list):
            raise ValueError("candidate trails are not structured lists")
        if any(
            not isinstance(item, dict)
            or item.get("eligible") is not True
            or item.get("reason") != "eligible"
            or not policy_candidate(cfg, role, item)
            for item in trail
        ):
            raise ValueError("eligible trail contains a refusal or foreign candidate")
        if any(
            not isinstance(item, dict)
            or item.get("eligible") is not False
            or not policy_candidate(cfg, role, item)
            for item in refusals
        ):
            raise ValueError("refusal trail contains an eligible or foreign candidate")
        chosen = resolved["chosen"]
        if chosen is None:
            if trail:
                raise ValueError("null chosen candidate still has an eligible trail")
            derived_degraded.append(role)
            continue
        if (
            not isinstance(chosen, dict)
            or not trail
            or not policy_candidate(cfg, role, chosen)
            or not fields_match(chosen, trail[0])
        ):
            raise ValueError("chosen candidate is not the first eligible trail entry")
    resolved_implementer = roles["implementer"]
    chosen_implementer = resolved_implementer["chosen"]
    if (
        not isinstance(chosen_implementer, dict)
        or any(
            chosen_implementer.get(key) != scope[scope_key]
            for key, scope_key in (
                ("agent", "implementer"),
                ("model", "implementer_model"),
                ("provider", "implementer_provider"),
            )
        )
    ):
        raise ValueError("resolved implementer does not match deciding scope")
    resolved_implementer_family = families.get(chosen_implementer.get("agent"))
    if (
        not nonempty(resolved_implementer_family)
        or resolved_implementer_family != scope["implementer_family"]
        or resolved_implementer_family != implementer_family
    ):
        raise ValueError(
            "resolved implementer family does not match deciding scope"
        )
    verdict_families = set()
    for role in SINGLE_VERDICT_ROLES:
        chosen = roles[role]["chosen"]
        if chosen is None:
            continue
        family = families.get(chosen.get("agent"))
        if not nonempty(family) or family == implementer_family:
            raise ValueError("chosen verdict shares the implementer family")
        if family in verdict_families:
            raise ValueError("chosen verdict family is duplicated")
        verdict_families.add(family)
    resolved = roles["refuter"]
    policy_required = role_specs["refuter"].get("required_seats")
    required = resolved["required_seats"]
    seats = resolved["seats"]
    if (
        policy_required != 3
        or not isinstance(required, int)
        or isinstance(required, bool)
        or required != 3
        or not isinstance(seats, list)
        or not 0 <= len(seats) <= required
    ):
        raise ValueError("refuter seats are not a valid partial or complete panel")
    trail = resolved["trail"]
    derived_seats = []
    seen_families = set()
    for entry in trail:
        family = families.get(entry.get("agent"))
        if not nonempty(family):
            raise ValueError("refuter trail family is unmapped")
        if family == implementer_family or family in verdict_families:
            raise ValueError("refuter trail reuses a reserved family")
        if family in seen_families:
            continue
        derived_seats.append(entry)
        seen_families.add(family)
        if len(derived_seats) >= required:
            break
    if len(seats) != len(derived_seats):
        raise ValueError("refuter seats do not match the eligible family prefix")
    seat_families = set()
    for seat, expected in zip(seats, derived_seats):
        if (
            not isinstance(seat, dict)
            or seat.get("eligible") is not True
            or seat.get("reason") != "eligible"
            or not policy_candidate(cfg, "refuter", seat)
            or not fields_match(seat, expected)
        ):
            raise ValueError("refuter seat is not the derived eligible prefix")
        fam = families.get(seat.get("agent"))
        if not nonempty(fam) or fam in seat_families:
            raise ValueError("refuter seat family is duplicated")
        seat_families.add(fam)
    chosen = resolved["chosen"]
    if not seats:
        if chosen is not None:
            raise ValueError("empty refuter panel still has a chosen candidate")
    elif (
        not isinstance(chosen, dict)
        or not fields_match(chosen, seats[0])
    ):
        raise ValueError("refuter chosen is not seat 0")
    if len(seats) < required:
        if "refuter" not in derived_degraded:
            derived_degraded.append("refuter")
    elif "refuter" in derived_degraded:
        raise ValueError("complete refuter panel is marked degraded")
    derived_verdict = [
        role for role in derived_degraded if role in VERDICT_ROLES
    ]
    if artifact["degraded_roles"] != derived_degraded:
        raise ValueError("degraded_roles do not match resolved rows")
    if artifact["degraded_verdict_roles"] != derived_verdict:
        raise ValueError("degraded_verdict_roles do not match verdict rows")
    ready = not derived_verdict
    if artifact["approval_ready"] is not ready:
        raise ValueError("approval_ready does not match verdict degradation")
    if scope["verdict_families_distinct"] is not ready:
        raise ValueError("verdict_families_distinct does not match verdict degradation")
except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"resolver artifact validation failed: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    clear_role_state
    echo "DEGRADED: deciding resolver artifact was missing, stale, unscoped, or malformed for implementer $IMPL; reviewer, security_reviewer, merge_reviewer, and refuter were not resolved. Do not substitute silently."
  fi
fi
