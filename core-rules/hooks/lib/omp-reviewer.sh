#!/usr/bin/env bash
# lib/omp-reviewer.sh — OMP-only non-Anthropic reviewer route.
#
# Source: Trellis / core-rules / hooks.md ("OMP owns its stop event. Any
# model-backed hook reached from that event MUST use the live non-Anthropic
# eval/role-resolver route supplied by the OMP adapter, or skip the model rung
# and use the deterministic fallback.").
#
# WHY THIS EXISTS: `claude -p` inside an OMP stop chain is a policy violation —
# it charges the Anthropic subscription OMP must never touch and re-fires the
# child's own Stop hooks (fork bomb). The canonical ladder's Claude/Codex rung 2
# is correct for those harnesses and MUST stay untouched; this lib is sourced
# ONLY by callers that already know they are running under OMP.
#
# CONTRACT:
#   stdin : a review envelope ({diff, autonomy_level, decisions_log} JSON or a
#           raw unified diff) — forwarded byte-for-byte, never parsed here.
#   stdout: EXACTLY one line of JSON {"findings":[...]} on success.
#   exit  : ALWAYS 0. Fail-open mirrors lib/code-reviewer.sh; blocking is the
#           caller's job. On every unavailable/failed route the caller falls
#           back to its deterministic path.
#
# ROUTE RESOLUTION (first that applies wins):
#   1. $CODE_REVIEWER_CMD resolvable on PATH → exec it with the untouched stdin
#      (operator override wins everywhere).
#   2. TRELLIS_OMP_REVIEW_CMD (PATH name, absolute, or relative-to-CWD path) →
#      exec'd the same way. This is the "live eval/role-resolver route" hook:
#      an operator can pin any non-Anthropic command without editing policy.
#   3. `omp` CLI present + python3 → validate the deciding
#      ~/.omp/agent/roles-resolved.json artifact, then one-turn `omp -p`
#      headless with `roles.reviewer.chosen.model` and tools OFF. The model is
#      consumed directly so resolver-only aliases need no agent markdown file.
#   No valid deciding artifact → return 1; the caller degrades to its
#   deterministic rung.
#
# ANTI-SPOOF GUARD: _omp_model_allowed refuses any model containing "claude",
# "anthropic", or "opus" (case-insensitive). The resolver roster is curated to
# be Anthropic-free, but a hand-edited roles artifact must not be able to
# smuggle this harness into charging Claude.
#
# SHELL-INJECTION SAFETY: no eval anywhere; the prompt is passed as ONE argv
# element to omp; the envelope rides stdin; every interpolated value is quoted.
# The fork-bomb sentinel TRELLIS_REVIEW_IN_PROGRESS=1 is exported around the
# child so any claude-family Stop chain it could trigger stays inert.
#
# bash 3.2 compatible: no namerefs / mapfile / associative arrays. Sets nothing
# at source time (safe to source from a running hook).

# ---------------------------------------------------------------------------
# _omp_reviewer_emit_empty — fail-open verdict line (jq-free, like the ladder).
# ---------------------------------------------------------------------------
_omp_reviewer_emit_empty() {
  printf '%s\n' '{"findings":[]}'
}

# ---------------------------------------------------------------------------
# _omp_reviewer_roles_config
#   Print the active release's canonical roles.json. A deciding artifact is
#   never authorized by a project copy, a legacy user copy, or this source tree:
#   those may be stale or hand-edited and must not extend its freshness.
# ---------------------------------------------------------------------------
_omp_reviewer_roles_config() {
  local trellis_home="${TRELLIS_HOME:-}"

  if [ -z "$trellis_home" ]; then
    [ -n "${HOME:-}" ] || return 1
    trellis_home="$HOME/.trellis"
  fi
  command -v python3 >/dev/null 2>&1 || return 1

  python3 - "$trellis_home" <<'PY'
import json
import os
import sys

try:
    home = sys.argv[1]
    with open(os.path.join(home, "config.json"), encoding="utf-8") as source:
        release = json.load(source).get("active_cli_release")
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
    payload = os.path.join(home, "releases", release, "payload")
    roles = os.path.join(
        payload, "core-rules", "skills", "herdr-foreman", "roles.json"
    )
    payload_real = os.path.realpath(payload)
    roles_real = os.path.realpath(roles)
    if (
        not os.path.isdir(payload_real)
        or not os.path.isfile(roles_real)
        or os.path.commonpath((payload_real, roles_real)) != payload_real
    ):
        raise ValueError("roles policy escapes the active release payload")
    sys.stdout.write(roles_real)
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

# ---------------------------------------------------------------------------
# _omp_resolve_reviewer_model
#   Validate the deciding resolver artifact and print reviewer.chosen.model.
#   Partial rosters are admissible only when reviewer itself is present,
#   independent, and not declared degraded; every available candidate/seat
#   must still validate. A degraded or missing reviewer fails closed.
# ---------------------------------------------------------------------------
_omp_resolve_reviewer_model() {
  local state_home="${HOME:-${TRELLIS_HOME:-}}" state="" config=""

  # roles-resolved.json is HOME-shared state. It is meaningful only in the
  # Herdr pane that produced its exact scoped decision.
  [ "${HERDR_ENV:-}" = "1" ] || return 1
  [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 1
  [ -n "${HERDR_PANE_ID:-}" ] || return 1

  if [ -n "${OMP_ROLE_STATE:-}" ]; then
    state="$OMP_ROLE_STATE"
  else
    [ -n "$state_home" ] || return 1
    state="$state_home/.omp/agent/roles-resolved.json"
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  config="$(_omp_reviewer_roles_config)" || return 1
  [ -f "$state" ] || return 1

  python3 - "$state" "$config" <<'PY'
import datetime as dt
import hashlib
import json
import math
import os
import stat
import sys

state_path, config_path = sys.argv[1:]
VERDICT_ROLE_ORDER = ("reviewer", "security_reviewer", "merge_reviewer", "refuter")
VERDICT_ROLES = set(VERDICT_ROLE_ORDER)
SINGLE_VERDICT_ROLES = ("reviewer", "security_reviewer", "merge_reviewer")
CANDIDATE_FIELDS = ("agent", "model", "provider", "remaining", "note")


def reject():
    raise ValueError("invalid deciding reviewer artifact")


def nonempty_string(value):
    return (
        isinstance(value, str)
        and bool(value)
        and value.strip() == value
        and "\x00" not in value
    )


def valid_positive_number(value):
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
        and value > 0
    )


def valid_remaining(value):
    return (
        value is None
        or (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(value)
        )
    )


def valid_candidate(entry, eligible):
    if not isinstance(entry, dict):
        return False
    if not all(nonempty_string(entry.get(key)) for key in ("agent", "model", "provider")):
        return False
    if entry.get("eligible") is not eligible:
        return False
    if eligible:
        if entry.get("reason") != "eligible":
            return False
    elif not nonempty_string(entry.get("reason")):
        return False
    if "remaining" not in entry or not valid_remaining(entry["remaining"]):
        return False
    return "note" not in entry or nonempty_string(entry["note"])


def valid_chosen(entry):
    return (
        isinstance(entry, dict)
        and all(nonempty_string(entry.get(key)) for key in ("agent", "model", "provider"))
        and "remaining" in entry
        and valid_remaining(entry["remaining"])
        and ("note" not in entry or nonempty_string(entry["note"]))
    )


def configured_identity(agents, agent):
    if not isinstance(agents, dict) or not nonempty_string(agent):
        return None
    facts = agents.get(agent)
    if not isinstance(facts, dict):
        return None
    identity = (agent, facts.get("model"), facts.get("provider"))
    family = facts.get("family")
    if not all(nonempty_string(value) for value in identity) or not nonempty_string(family):
        return None
    return identity


def catalog_family(agents, agent):
    if not isinstance(agents, dict) or not nonempty_string(agent):
        return None
    facts = agents.get(agent)
    if not isinstance(facts, dict):
        return None
    family = facts.get("family")
    return family if nonempty_string(family) else None


def family_map(agents):
    if not isinstance(agents, dict) or not agents:
        return None
    mapping = {}
    for name, facts in agents.items():
        family = catalog_family(agents, name)
        if family is None or not isinstance(facts, dict):
            return None
        mapping[name] = family
    return mapping


def candidate_matches_policy(config, role, entry):
    if not isinstance(entry, dict):
        return False
    agent = entry.get("agent")
    role_specs = config.get("roles")
    spec = role_specs.get(role) if isinstance(role_specs, dict) else None
    chain = spec.get("chain") if isinstance(spec, dict) else None
    identity = configured_identity(config.get("agents"), agent)
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


def fields_match(left, right):
    return all(left.get(key) == right.get(key) for key in CANDIDATE_FIELDS)


def read_private_regular(path):
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        reject()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or (metadata.st_dev, metadata.st_ino) != (before.st_dev, before.st_ino)
        ):
            reject()
        with os.fdopen(descriptor, "r", encoding="utf-8") as source:
            descriptor = None
            return json.load(source)
    finally:
        if descriptor is not None:
            os.close(descriptor)


try:
    with open(config_path, "rb") as source:
        policy_bytes = source.read()
    config = json.loads(policy_bytes)
    ttl = config.get("cache_ttl_seconds", 600)
    if not valid_positive_number(ttl):
        reject()
    role_specs = config.get("roles")
    agents = config.get("agents")
    families = family_map(agents)
    if not isinstance(role_specs, dict) or families is None:
        reject()
    artifact = read_private_regular(state_path)
    if not isinstance(artifact, dict):
        reject()
    policy = artifact.get("roles_policy")
    if (
        not isinstance(policy, dict)
        or set(policy) != {"roles_sha256", "cache_ttl_seconds"}
        or not isinstance(policy.get("roles_sha256"), str)
        or len(policy["roles_sha256"]) != 64
        or any(character not in "0123456789abcdef" for character in policy["roles_sha256"])
        or not valid_positive_number(policy.get("cache_ttl_seconds"))
        or policy["roles_sha256"] != hashlib.sha256(policy_bytes).hexdigest()
        or policy["cache_ttl_seconds"] != ttl
    ):
        reject()

    if os.environ.get("HERDR_ENV") != "1":
        reject()
    workspace = os.environ.get("HERDR_WORKSPACE_ID")
    pane = os.environ.get("HERDR_PANE_ID")
    if not nonempty_string(workspace) or not nonempty_string(pane):
        reject()
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
        or not all(
            nonempty_string(scope.get(key))
            for key in (
                "implementer",
                "implementer_model",
                "implementer_provider",
                "implementer_family",
                "herdr_workspace_id",
                "herdr_pane_id",
            )
        )
        or scope["herdr_workspace_id"] != workspace
        or scope["herdr_pane_id"] != pane
    ):
        reject()
    identity = configured_identity(agents, scope["implementer"])
    if identity != (
        scope["implementer"],
        scope["implementer_model"],
        scope["implementer_provider"],
    ):
        reject()
    implementer_family = families.get(scope["implementer"])
    if (
        not nonempty_string(implementer_family)
        or scope["implementer_family"] != implementer_family
    ):
        reject()
    if artifact["family_collapse"] != []:
        reject()

    resolved_at = artifact.get("resolved_at")
    if not nonempty_string(resolved_at):
        reject()
    parsed_at = dt.datetime.fromisoformat(
        resolved_at[:-1] + "+00:00" if resolved_at.endswith("Z") else resolved_at
    )
    if parsed_at.tzinfo is None or parsed_at.utcoffset() is None:
        reject()
    age = (dt.datetime.now(dt.timezone.utc) - parsed_at.astimezone(dt.timezone.utc)).total_seconds()
    if age < 0 or age > ttl:
        reject()

    nonce = artifact.get("resolution_nonce")
    if not nonempty_string(nonce):
        reject()

    roles = artifact["roles"]
    if not isinstance(roles, dict) or set(roles) != set(role_specs):
        reject()
    derived_degraded = []
    for role in role_specs:
        resolved = roles[role]
        if not nonempty_string(role) or not isinstance(resolved, dict):
            reject()
        trail = resolved["trail"]
        refusals = resolved["refusals"]
        if not isinstance(trail, list) or not isinstance(refusals, list):
            reject()
        if not all(
            valid_candidate(entry, True)
            and candidate_matches_policy(config, role, entry)
            for entry in trail
        ):
            reject()
        if not all(
            valid_candidate(entry, False)
            and candidate_matches_policy(config, role, entry)
            for entry in refusals
        ):
            reject()
        chosen = resolved["chosen"]
        if chosen is None:
            if trail:
                reject()
            derived_degraded.append(role)
            continue
        if (
            not valid_chosen(chosen)
            or not trail
            or not candidate_matches_policy(config, role, chosen)
            or not fields_match(chosen, trail[0])
        ):
            reject()

    resolved_implementer = roles["implementer"]
    chosen_implementer = resolved_implementer["chosen"]
    if (
        not valid_chosen(chosen_implementer)
        or any(
            chosen_implementer.get(key) != scope[scope_key]
            for key, scope_key in (
                ("agent", "implementer"),
                ("model", "implementer_model"),
                ("provider", "implementer_provider"),
            )
        )
    ):
        reject()
    resolved_implementer_family = families.get(
        chosen_implementer["agent"]
    )
    if (
        not nonempty_string(resolved_implementer_family)
        or resolved_implementer_family != scope["implementer_family"]
        or resolved_implementer_family != implementer_family
    ):
        reject()

    verdict_families = set()
    for role in SINGLE_VERDICT_ROLES:
        chosen = roles[role]["chosen"]
        if chosen is None:
            continue
        family = families.get(chosen["agent"])
        if (
            not nonempty_string(family)
            or family == implementer_family
            or family in verdict_families
        ):
            reject()
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
        reject()
    trail = resolved["trail"]
    derived_seats = []
    seen_families = set()
    for entry in trail:
        family = families.get(entry.get("agent"))
        if not nonempty_string(family):
            reject()
        if family == implementer_family or family in verdict_families:
            reject()
        if family in seen_families:
            continue
        derived_seats.append(entry)
        seen_families.add(family)
        if len(derived_seats) >= required:
            break
    if len(seats) != len(derived_seats):
        reject()
    seat_families = set()
    for seat, expected in zip(seats, derived_seats):
        if (
            not valid_candidate(seat, True)
            or not candidate_matches_policy(config, "refuter", seat)
            or not fields_match(seat, expected)
        ):
            reject()
        fam = families.get(seat.get("agent"))
        if not nonempty_string(fam) or fam in seat_families:
            reject()
        seat_families.add(fam)
    chosen = resolved["chosen"]
    if not seats:
        if chosen is not None:
            reject()
    elif not valid_chosen(chosen) or not fields_match(chosen, seats[0]):
        reject()
    if len(seats) < required:
        if "refuter" not in derived_degraded:
            derived_degraded.append("refuter")
    elif "refuter" in derived_degraded:
        reject()

    derived_verdict = [
        role for role in derived_degraded if role in VERDICT_ROLES
    ]
    if artifact["degraded_roles"] != derived_degraded:
        reject()
    if artifact["degraded_verdict_roles"] != derived_verdict:
        reject()
    ready = not derived_verdict
    if artifact["approval_ready"] is not ready:
        reject()
    if scope["verdict_families_distinct"] is not ready:
        reject()

    reviewer_chosen = roles["reviewer"]["chosen"]
    if (
        reviewer_chosen is None
        or "reviewer" in derived_degraded
        or "reviewer" in derived_verdict
    ):
        reject()
    sys.stdout.write(reviewer_chosen["model"])
except (KeyError, OSError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

# ---------------------------------------------------------------------------
# _omp_model_allowed <model>
#   Refuse any resolver-selected model that can reach Anthropic.
# ---------------------------------------------------------------------------
_omp_model_allowed() {
  local model="$1" lower=""
  [ -n "$model" ] || return 1
  lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *claude*|*anthropic*|*opus*)
      printf 'omp-reviewer: resolved model "%s" looks Anthropic; refusing.\n' "$model" >&2
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# _omp_llm_review <prompt> [timeout_secs]
#   One-turn `omp -p` review. Envelope on stdin, findings line on stdout.
#   Returns 0 only when omp produced a nonempty reply; any failure returns 1 so
#   the caller falls through to its deterministic rung.
# ---------------------------------------------------------------------------
_omp_llm_review() {
  local prompt="$1" secs="${2:-120}" model="" raw=""

  # Only a current, structurally valid deciding artifact with an independent
  # non-degraded reviewer can select the model route. There is deliberately
  # no agent-markdown or fixed-model fallback here: those bypass the scoped
  # resolver's cross-family decision.
  model="$(_omp_resolve_reviewer_model)" || {
    echo "omp-reviewer: deciding artifact is unavailable or invalid; deterministic OMP fallback applies" >&2
    return 1
  }
  _omp_model_allowed "$model" || {
    echo "omp-reviewer: resolved model refusal; deterministic OMP fallback applies" >&2
    return 1
  }

  # Fork-bomb guard: any Stop-hook-bearing child spawned below sees the
  # sentinel and bails at the top of its own hook (same contract as
  # lib/code-reviewer.sh rungs 1-2).
  export TRELLIS_REVIEW_IN_PROGRESS=1

  if ! raw="$(printf '%s' "$prompt" \
      | _omp_run_with_timeout "$secs" omp -p --no-session --no-tools --no-extensions --no-skills \
          --model "$model" -)"; then
    return 1
  fi
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

# ---------------------------------------------------------------------------
# _omp_run_with_timeout <secs> <cmd...> — perl-alarm wall-clock cap, identical
# shim to lib/code-reviewer.sh's (duplicated, NOT sourced: that file has
# side effects and pulls in the whole reviewer ladder).
# ---------------------------------------------------------------------------
_omp_run_with_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      if (!defined $pid) { exec @ARGV; }
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
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
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# main — resolve the OMP route and emit exactly one verdict line. Run only when
# executed (mirrors code-reviewer.sh's main-guard so bats can unit-test parts).
# ---------------------------------------------------------------------------
_omp_reviewer_main() {
  # Rung A: operator/resolver override — exec'd with the untouched stdin, the
  # exact contract of ladder rung 1.
  if [ -n "${CODE_REVIEWER_CMD:-}" ] && command -v "${CODE_REVIEWER_CMD}" >/dev/null 2>&1; then
    export TRELLIS_REVIEW_IN_PROGRESS=1
    exec "${CODE_REVIEWER_CMD}"
  fi
  if [ -n "${TRELLIS_OMP_REVIEW_CMD:-}" ] && command -v "${TRELLIS_OMP_REVIEW_CMD}" >/dev/null 2>&1; then
    export TRELLIS_REVIEW_IN_PROGRESS=1
    exec "${TRELLIS_OMP_REVIEW_CMD}"
  fi

  # Rung B: live non-Anthropic omp route.
  if command -v omp >/dev/null 2>&1; then
    local prompt verdict
    prompt="$(cat)"
    verdict="$(_omp_llm_review "$prompt")" || { _omp_reviewer_emit_empty; return 0; }
    printf '%s\n' "$verdict"
    return 0
  fi

  # No route: degrade loudly-but-openly (stderr breadcrumb + empty verdict,
  # exit 0) so a direct invocation honors the same fail-open contract as the
  # canonical ladder; callers with their own deterministic rung key off the
  # empty findings and run it.
  echo "omp-reviewer: no non-Anthropic reviewer route available (set CODE_REVIEWER_CMD or TRELLIS_OMP_REVIEW_CMD); deterministic fallback applies" >&2
  _omp_reviewer_emit_empty
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -uo pipefail
  _omp_reviewer_main "$@"
fi
