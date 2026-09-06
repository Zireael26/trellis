#!/usr/bin/env bash
# code-reviewer.sh — canonical reusable code-review decision core (reviewer
# ladder rungs 2 + 3). The single source of the review verdict.
#
# Source: Trellis / core-rules / hooks.md (E1 reviewer ladder).
# Plan: docs/specs/2026-06-02-trellis-process-enforcement-design.md §Phase 1.
#
# Both callers depend on this file being the only place the verdict is decided:
#   - Phase-2a Stop hook   : core-rules/hooks/code-review-subagent.sh
#   - Phase-4 execute body : core-rules/skills/execute/SKILL.md (advisory path)
#
# CONTRACT (keep accurate — Phase-2a wiring + the bats suite key off it):
#   stdin  : a review envelope. EITHER a JSON object
#            {diff, autonomy_level, decisions_log}  OR (if not JSON) a raw
#            unified diff. Tolerant: jq present → parse; else raw diff.
#   stdout : EXACTLY one line of JSON with a findings array. Built-in LLM
#            success includes status=completed; deterministic-only and legacy
#            override envelopes may omit status. A failed rung 2 includes
#            status=degraded with deterministic fallback findings. The CALLER
#            decides block/allow.
#   exit   : The built-in ladder exits 0 after deterministic fallback; a rung-1
#            exec propagates the operator reviewer's status. Rung-2 infra failure
#            (claude error/timeout, perl missing, unparseable output) stays
#            fail-open while the deterministic rung scans the diff. Blocking is
#            the caller's job.
#
#   LADDER (first that works wins):
#     rung 1: $CODE_REVIEWER_CMD set + resolvable → exec it (operator override),
#             passing the untouched stdin through.
#     rung 2a: inside Herdr (`HERDR_ENV=1`) with `pi` on PATH and a current
#             deciding artifact at ~/.trellis/state/roles-resolved.json that is
#             authorized by the active immutable release roles.json, scoped to
#             this exact workspace/pane, fresh, private regular mode 0600,
#             policy-bound, cross-family, and non-degraded → one-turn
#             `pi -p --no-session --no-tools --no-extensions --no-skills
#             --no-prompt-templates --no-themes --no-context-files --no-approve
#             --model "$model"` with the reviewer prompt as the positional
#             argument and the envelope on stdin. No Anthropic fallback, no
#             fixed-model or agent-file fallback. Recursion guard applies.
#     rung 2b: outside Herdr, `claude` on PATH → one-turn LLM reviewer
#             (verified invocation), unless the recursion guard is already set.
#     rung 3: deterministic regex fallback (ALWAYS available) — committed-secret
#             criticals + left-in-debugger important. Conservative by design:
#             false criticals cause false hard-blocks downstream.
#
#   env vars:
#     CODE_REVIEWER_CMD          — operator override (rung 1). PATH name or path.
#     TRELLIS_REVIEW_IN_PROGRESS — fork-bomb sentinel. ==1 on entry → skip LLM
#                                  rungs. Exported =1 before the pi/claude call
#                                  so the child's Stop hook does not re-fire.
#
#   functions (sourceable for bats):
#     deterministic_review  — rung 3 core; reads a raw diff on stdin, prints
#                             one-line findings JSON, returns 0. Pure: safe to
#                             source and unit-test.
#
# MIRROR-CLEAN: published to the public template. No operator-specific paths.
#
# bash 3.2 compatible: no namerefs / mapfile / associative arrays.
#
# `set -euo pipefail` is applied INSIDE the run-as-main guard at the bottom, NOT
# at file top: this file is sourced in-process (the bats suite + the Phase-4
# execute body), and top-level set flags would leak -e/-u/pipefail into the
# caller (mirrors lib/ui-verify-core.sh + lib/deps.sh/pm.sh, which set nothing at
# source time). Every function below guards its own fallible probes (|| true /
# `if cmd`), so each is correct whether or not -e is active.

# ---------------------------------------------------------------------------
# run_with_timeout <secs> <cmd...>
#   Portable wall-clock timeout. GNU `timeout` (and gtimeout) are ABSENT on
#   macOS, so we use a perl shim. It runs the command in its OWN process group
#   (setsid) and, on timeout, kills the WHOLE group — a bare SIGALRM reaches only
#   the direct child, so a grandchild (e.g. claude's Node descendants + a long
#   HTTP request) would otherwise keep the captured pipe open past the deadline.
#   Exits 142 on timeout; propagates the command's own exit status otherwise.
#   If Perl or its process setup is unavailable, returns 125 without starting
#   the command. A reviewer must never run without a wall-clock cap.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local secs="$1"; shift
  if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' 'code-reviewer: review degraded: bounded runner unavailable (Perl not found); deterministic fallback will be used' >&2
    return 125
  fi

  perl -e '
    use POSIX ();
    my $secs = shift @ARGV;
    my $pid = fork();
    if (!defined $pid) {
      print STDERR "code-reviewer: review degraded: timeout fork failed; reviewer was not started\n";
      exit(125);
    }
    if ($pid == 0) { POSIX::setsid(); exec @ARGV or POSIX::_exit(127); }
    $SIG{ALRM} = sub {
      kill("TERM", -$pid);
      # SAFETY: 0.3 s is the bounded TERM grace within the documented 60 s review budget (core-rules/hooks.md § Budget discipline); KILL follows.
      select(undef, undef, undef, 0.3);
      kill("KILL", -$pid); waitpid($pid, 0); exit(142);
    };
    # SAFETY: $secs is 55 s in production, leaving 5 s cleanup inside the documented 60 s review budget (core-rules/hooks.md § Budget discipline); status 142 takes the degraded deterministic fallback.
    alarm $secs;
    waitpid($pid, 0);
    my $st = $?;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
  ' "$secs" "$@"
}

# ---------------------------------------------------------------------------
# emit_empty — the literal fail-open verdict. Never uses jq (jq may be absent).
# ---------------------------------------------------------------------------
emit_empty() {
  printf '%s\n' '{"findings":[]}'
}

# Add a machine-readable degraded status to a deterministic findings envelope.
# deterministic_review owns the exact prefix, so this does not need jq.
emit_degraded() {
  local verdict="$1"
  case "$verdict" in
    '{"findings":'*) printf '%s\n' "{\"status\":\"degraded\",${verdict#\{}" ;;
    *) printf '%s\n' '{"status":"degraded","findings":[]}' ;;
  esac
}

# ---------------------------------------------------------------------------
# json_escape <string>
#   Minimal JSON string escaper for hand-built findings (rung 3) so the
#   deterministic rung never depends on jq. Escapes backslash, double-quote,
#   and the control chars that would break a single-line JSON value. Prints
#   the escaped body WITHOUT surrounding quotes.
# ---------------------------------------------------------------------------
json_escape() {
  # Order matters: backslash first. tr removes raw newlines/tabs/CR (paths/msgs
  # here never legitimately contain them). Failure → empty (fail-open).
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr -d '\n\r\t' \
    || printf ''
}

# ---------------------------------------------------------------------------
# deterministic_review — rung 3.
#   Reads a RAW unified diff on stdin. Scans ADDED lines only (lines starting
#   with '+' but not '+++'). Emits ONE line of findings JSON, returns 0.
#
#   critical (committed secrets ONLY — conservative to avoid false hard-blocks):
#     - AWS access key id            : AKIA[0-9A-Z]{16}
#     - PEM private key header       : -----BEGIN [A-Z ]*PRIVATE KEY-----
#     - QUOTED, non-empty, non-placeholder literal assigned to a secret-named key
#       (password/secret/api[_-]?key/token/access[_-]?key); NOT an unquoted type
#       annotation, an env-var/process.env reference, or a placeholder.
#   important (obvious left-in debugger):
#     - binding.pry | a left-in JS debugger statement | import pdb
#   otherwise: {"findings":[]}.
#
#   Pure + side-effect-free: safe for the bats suite to source and call. Every
#   fallible probe is guarded so file-top `set -e` cannot abort a sourcing test.
# ---------------------------------------------------------------------------
deterministic_review() {
  local diff added findings_json="" sep=""

  # Read all of stdin (the raw diff). `cat` on empty stdin returns "" cleanly.
  diff="$(cat || true)"

  # Added lines only: '+' but not '+++'. grep returns 1 on no-match → guard it.
  added="$(printf '%s\n' "$diff" | grep -E '^\+([^+]|$)' || true)"
  if [ -z "$added" ]; then
    emit_empty
    return 0
  fi

  # --- critical: AWS access key id ---
  if printf '%s\n' "$added" | grep -Eq 'AKIA[0-9A-Z]{16}'; then
    findings_json="${findings_json}${sep}$(_det_finding critical "AWS access key id committed in diff")"
    sep=","
  fi

  # --- critical: PEM private key header ---
  if printf '%s\n' "$added" | grep -Eq -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    findings_json="${findings_json}${sep}$(_det_finding critical "Private key (PEM) committed in diff")"
    sep=","
  fi

  # --- critical: hard-coded secret literal assigned to a credential-named key ---
  # A committed secret is a secret-named key assigned a QUOTED, non-empty,
  # non-placeholder string LITERAL. Requiring quotes is the precision lever: it
  # distinguishes a real assignment (a credential-named key set to a quoted
  # literal) from a TYPE ANNOTATION / struct field / GraphQL field (password: string,
  # api_key: String!, apiKey: ApiKey) — those are UNQUOTED, so they never match.
  # We then drop env-var dereferences and obvious placeholders. Rung 3 is the SOLE
  # reviewer when claude is absent, so a false critical is a false hard-block: we
  # favour precision over recall (an unquoted YAML/env secret is a tolerated miss;
  # the LLM rung catches those).
  # A credential-named key assigned a QUOTED, non-empty, non-placeholder string
  # LITERAL — keyword, operator, and value adjacent on one line. Requiring QUOTES
  # is the precision lever: it ignores TYPE ANNOTATIONS / struct / GraphQL fields
  # (password: string, api_key: String!, apiKey: ApiKey) which are UNQUOTED, and
  # requiring >=1 char between the quotes ignores empty values (password = "").
  # (':'/'=' via the (:|=) alternation, not a bracket class [:=] — '[:' can open
  # a POSIX char-class, which makes [:=] ambiguous.) Rung 3 is the SOLE reviewer
  # when claude is absent, so a false critical is a false hard-block: we favour
  # precision over recall — an unquoted YAML/env secret is a tolerated miss (the
  # LLM rung catches those).
  local secret_hits
  secret_hits="$(printf '%s\n' "$added" \
    | grep -iE "(password|passwd|secret|api[_-]?key|token|access[_-]?key)[[:space:]]*(:|=)[[:space:]]*[\"'][^\"']+[\"']" \
    || true)"
  if [ -n "$secret_hits" ]; then
    # Drop lines whose value is an env reference (not a hard-coded literal).
    secret_hits="$(printf '%s\n' "$secret_hits" \
      | grep -ivE '(:|=)[[:space:]]*[\"'\'']?(\$\{?[A-Za-z_]|process\.env|os\.environ|os\.getenv|getenv\(|ENV\[)' \
      || true)"
    # Drop obvious placeholders / templated values (not a real committed secret).
    secret_hits="$(printf '%s\n' "$secret_hits" \
      | grep -ivE '(REPLACE|CHANGE[_-]?ME|CHANGEME|YOUR[_-]|EXAMPLE|PLACEHOLDER|DUMMY|SAMPLE|XXXX|TODO|FIXME|<[^>]+>)' \
      || true)"
    if [ -n "$secret_hits" ]; then
      findings_json="${findings_json}${sep}$(_det_finding critical "Hard-coded secret literal assigned to a credential-named key")"
      sep=","
    fi
  fi

  # --- important: obvious left-in debugger ---
  # Middle alternative uses a bracketed terminator so this file does not
  # self-match in a diff (DL-P8a-09); it matches the same target text.
  if printf '%s\n' "$added" | grep -Eq 'binding\.pry|debugger[;]|import pdb'; then
    findings_json="${findings_json}${sep}$(_det_finding important "Left-in debugger statement")"
    sep=","
  fi

  printf '%s\n' "{\"findings\":[${findings_json}]}"
  return 0
}

# _det_finding <severity> <msg>  — hand-build one finding object (no jq).
# Deterministic rung has no reliable file/line, so file="" line=0; confidence
# fixed at 0.9 (high but not absolute, per the schema's 0.0-1.0).
_det_finding() {
  local sev="$1" msg="$2" emsg
  emsg="$(json_escape "$msg")"
  printf '{"severity":"%s","file":"","line":0,"msg":"%s","confidence":0.9}' "$sev" "$emsg"
}

# ---------------------------------------------------------------------------
# REVIEWER PROMPT — embedded verbatim. KEEP IDENTICAL to agents/code-reviewer.md.
# Quoted heredoc (<<'PROMPT_EOF') so the apostrophe in "turn's" and the JSON
# schema's double-quotes/braces survive byte-for-byte with no expansion.
# (propose-rules.sh avoided apostrophes via single-quotes; a verbatim prompt
# cannot be reworded, hence the heredoc.)
# ---------------------------------------------------------------------------
read_reviewer_prompt() {
  cat <<'PROMPT_EOF'
You are a code reviewer for a single turn's diff. Read the JSON object on stdin: it has keys
.diff (a unified git diff string; if stdin is not JSON, treat the whole stdin as the raw diff),
.autonomy_level (1-5 int), and .decisions_log (string, may be empty).
Review ONLY the added/changed lines in .diff. Output ONLY a single-line JSON object, no prose, no markdown fence:
{"findings":[{"severity":"critical|important|minor","file":"path","line":N,"msg":"short","confidence":0.0-1.0}]}
If nothing is wrong, output exactly {"findings":[]}.
"critical" is RESERVED for exactly three classes and nothing else:
  (1) security hole introduced by the diff (committed secret/credential, injection, auth/authz bypass, unsafe deserialization, path traversal),
  (2) data loss (destructive op without guard: rm -rf on a variable, DROP/DELETE without WHERE, truncate),
  (3) broken build (syntax error, undefined symbol the diff relies on, import of something not present).
Everything else is "important" or "minor". When in doubt between critical and important, choose important. Never invent issues to seem useful.
Report every real finding, including low-severity and low-confidence ones — do not omit a finding because it seems unimportant. Set severity and confidence honestly and let the caller rank and gate; coverage is your job, filtering is not.
PROMPT_EOF
}

# ---------------------------------------------------------------------------
# extract_raw_diff <envelope>
#   If jq present and the envelope parses as a JSON object, return .diff.
#   Otherwise (not JSON, jq absent, or jq error) return the envelope as-is —
#   it is then treated as a raw diff. Never errors.
# ---------------------------------------------------------------------------
extract_raw_diff() {
  local envelope="$1" out
  if command -v jq >/dev/null 2>&1; then
    # -e: jq exits non-zero if the input isn't valid JSON or .diff is null.
    out="$(printf '%s' "$envelope" | jq -er '.diff // empty' 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  # Fall back: treat the whole envelope as the raw diff.
  printf '%s' "$envelope"
}

# ---------------------------------------------------------------------------
# normalize_findings <text>
#   Validate the LLM output is parseable JSON with a .findings array; if so,
#   re-emit it compact (one line) with status=completed. If not salvageable →
#   return 1 (caller falls through to rung 3 / empty). With jq: strict validation
#   + compaction. Without
#   jq: a tolerant check that the text contains a "findings" array shell and is
#   a single object — accept it as-is if so, else fail. Never crashes.
# ---------------------------------------------------------------------------
normalize_findings() {
  local text="$1" out
  [ -n "$text" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    # Require an object with a .findings array. -c → single compact line.
    # Slurp (-s) collapses a stream of >1 JSON value into one array, then take
    # the first valid findings object — guarantees a single output line even if
    # the model emits multiple objects. `// empty` → no output when none match.
    if out="$(printf '%s' "$text" | jq -ces '[ .[] | select(type=="object" and (.findings|type=="array")) | {status: "completed", findings: .findings} ] | (.[0] // empty)')"; then
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
    return 1
  fi
  # jq-less tolerant path: accept only if it looks like a single-line findings
  # object. Collapse to one line; require a leading '{' and a "findings" key.
  out="$(printf '%s' "$text" | tr -d '\n\r' || true)"
  case "$out" in
    \{*\"findings\"*\}) printf '%s\n' "$out"; return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# llm_review <envelope>
#   rung 2. Pipe the envelope to a one-turn `claude -p`, embedding the verbatim
#   reviewer prompt as the trailing arg. Wrapped in the perl-alarm timeout
#   (55s). Returns the normalized findings JSON on success, returns 1 on any
#   failure (so the caller falls through to rung 3). claude stderr is NOT
#   suppressed (per the documented mistake to avoid) — only stdout is captured.
# ---------------------------------------------------------------------------
llm_review() {
  local envelope="$1" prompt raw norm reviewer_status
  prompt="$(read_reviewer_prompt || true)"
  if [ -z "$prompt" ]; then
    printf '%s\n' 'code-reviewer: review degraded: reviewer prompt unavailable; deterministic fallback will be used' >&2
    return 1
  fi

  # Fork-bomb guard: export the sentinel so the claude child's own Stop hook
  # sees TRELLIS_REVIEW_IN_PROGRESS=1 and skips re-firing the reviewer.
  export TRELLIS_REVIEW_IN_PROGRESS=1

  # Capture stdout only. Run inside `if` so a non-zero exit (timeout 142,
  # claude error, etc.) does not trip file-top `set -e`.
  #
  # The envelope is ATTACKER-INFLUENCEABLE (it is the diff under review), so the
  # reviewer must run with ZERO host tools: it only reads the prompt and emits
  # JSON to stdout. `--tools Read` makes the AVAILABLE tool-set EXCLUSIVE (Read +
  # advisor only) — Bash / Edit / Write / Agent / Workflow / Skill / ToolSearch
  # are not even present, so a prompt-injected diff cannot induce a host tool_use
  # regardless of the host's permissions.defaultMode (which can be `auto` =
  # auto-allow headless). A mere `--disallowedTools` denylist is INCOMPLETE here:
  # the default set includes ToolSearch (loads further deferred tools) + agent-
  # spawn tools, so restricting the available set is the airtight lever. `--tools`
  # is variadic, but the `--max-budget-usd` flag after it terminates the list, so
  # the trailing positional "$prompt" is not consumed.
  if raw="$(printf '%s' "$envelope" \
      | run_with_timeout 55 claude -p --max-turns 1 --output-format text \
          --tools Read \
          --max-budget-usd 0.50 "$prompt")"; then
    :
  else
    reviewer_status=$?
    case "$reviewer_status" in
      125) : ;; # The bounded runner already emitted the single degradation.
      142) printf '%s\n' 'code-reviewer: review degraded: reviewer timed out; deterministic fallback will be used' >&2 ;;
      *) printf '%s\n' 'code-reviewer: review degraded: reviewer command failed; deterministic fallback will be used' >&2 ;;
    esac
    return 1
  fi

  if norm="$(normalize_findings "$raw")"; then
    :
  else
    printf '%s\n' 'code-reviewer: review degraded: reviewer returned a malformed findings envelope; deterministic fallback will be used' >&2
    return 1
  fi
  printf '%s\n' "$norm"
  return 0
}

# ---------------------------------------------------------------------------
# reviewer_roles_config
#   Print the active release's canonical roles.json. A deciding artifact is
#   never authorized by a project copy, a legacy user copy, or this source tree:
#   those may be stale or hand-edited and must not extend its freshness.
# ---------------------------------------------------------------------------
reviewer_roles_config() {
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
# resolve_reviewer_model
#   Validate the deciding resolver artifact and print reviewer.chosen.model.
#   Partial rosters are admissible only when reviewer itself is present,
#   independent, and not declared degraded; every available candidate/seat
#   must still validate. A degraded or missing reviewer fails closed.
# ---------------------------------------------------------------------------
resolve_reviewer_model() {
  local state_home="${HOME:-${TRELLIS_HOME:-}}" state="" config=""

  # roles-resolved.json is HOME-shared Trellis state. It is meaningful only in
  # the Herdr pane that produced its exact scoped decision.
  [ "${HERDR_ENV:-}" = "1" ] || return 1
  [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 1
  [ -n "${HERDR_PANE_ID:-}" ] || return 1

  [ -n "$state_home" ] || return 1
  state="$state_home/.trellis/state/roles-resolved.json"
  command -v python3 >/dev/null 2>&1 || return 1
  config="$(reviewer_roles_config)" || return 1
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
# reviewer_model_allowed <model>
#   Refuse any resolver-selected model that can reach Anthropic.
# ---------------------------------------------------------------------------
reviewer_model_allowed() {
  local model="$1" lower=""
  [ -n "$model" ] || return 1
  lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *claude*|*anthropic*|*opus*)
      printf 'code-reviewer: resolved model "%s" looks Anthropic; refusing.\n' "$model" >&2
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# pi_review <envelope>
#   Cross-family one-turn `pi -p` review. Envelope on stdin, reviewer prompt as
#   the positional argument, findings line on stdout. Returns 0 only when pi
#   produced a normalizeable findings object; any failure returns 1 so the
#   caller falls through to its deterministic rung. No fixed-model or
#   agent-file fallback.
# ---------------------------------------------------------------------------
pi_review() {
  local envelope="$1" prompt raw norm model=""

  prompt="$(read_reviewer_prompt || true)"
  [ -n "$prompt" ] || return 1

  # Only a current, structurally valid deciding artifact with an independent
  # non-degraded reviewer can select the model route.
  model="$(resolve_reviewer_model)" || {
    echo "code-reviewer: deciding artifact is unavailable or invalid; deterministic fallback applies" >&2
    return 1
  }
  reviewer_model_allowed "$model" || {
    echo "code-reviewer: resolved model refusal; deterministic fallback applies" >&2
    return 1
  }

  export TRELLIS_REVIEW_IN_PROGRESS=1

  if raw="$(printf '%s' "$envelope" \
      | run_with_timeout 55 pi -p --no-session --no-tools --no-extensions --no-skills \
          --no-prompt-templates --no-themes --no-context-files --no-approve \
          --model "$model" "$prompt")"; then
    :
  else
    return 1
  fi

  norm="$(normalize_findings "$raw" || true)"
  [ -n "$norm" ] || return 1
  printf '%s\n' "$norm"
  return 0
}

# ---------------------------------------------------------------------------
# main — resolve the ladder and emit exactly one verdict line.
# ---------------------------------------------------------------------------
main() {
  # --- rung 1: operator override. Resolve + exec BEFORE consuming stdin so it
  # gets the untouched envelope on fd 0. `command -v` resolves both a PATH name
  # and an absolute/relative path that is executable.
  if [ -n "${CODE_REVIEWER_CMD:-}" ] && command -v "${CODE_REVIEWER_CMD}" >/dev/null 2>&1; then
    # Fork-bomb guard for the rung-1 path too: an operator reviewer that itself
    # spawns `claude` would otherwise re-fire the Stop hook recursively. Export
    # the sentinel before the exec so that child's top-of-hook guard trips. (The
    # rung-2 path exports the same sentinel inside llm_review.) Scoped to this
    # branch — it never runs when rung 1 is absent, so rung 2 stays reachable.
    export TRELLIS_REVIEW_IN_PROGRESS=1
    exec "${CODE_REVIEWER_CMD}"
    # exec replaces this process; nothing below runs on success.
  fi

  # stdin is single-shot — read it once, now.
  local INPUT
  INPUT="$(cat || true)"

  # --- rung 2: LLM reviewer, unless the recursion guard is already tripped.
  # Inside Herdr the only model route is cross-family pi (validated deciding
  # artifact). Same-family Claude is never a fallback on that path. Outside
  # Herdr the Claude Code/Codex `claude -p` rung remains. A failed claude rung
  # falls through to rung 3 and is carried in the output envelope so callers
  # do not record that fallback as a completed LLM review. Herdr pi fail-closed
  # (no valid deciding artifact / no pi) is the intended deterministic path,
  # not a degraded LLM attempt.
  local review_degraded=0 verdict
  if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" != "1" ]; then
    if [ "${HERDR_ENV:-}" = "1" ]; then
      if command -v pi >/dev/null 2>&1; then
        if verdict="$(pi_review "$INPUT")"; then
          printf '%s\n' "$verdict"
          return 0
        fi
      fi
    elif command -v claude >/dev/null 2>&1; then
      if verdict="$(llm_review "$INPUT")"; then
        # Uniform framing with rung 3 / emit_empty: exactly one newline-terminated
        # line. ($() stripped any trailing newline from $verdict, so add one back.)
        printf '%s\n' "$verdict"
        return 0
      fi
      review_degraded=1
    fi
  fi

  # --- rung 3: deterministic fallback (always available). Scan the DECODED
  # diff (envelope .diff if JSON, else the whole input as a raw diff).
  local raw_diff
  raw_diff="$(extract_raw_diff "$INPUT" || true)"
  if [ "$review_degraded" -eq 1 ]; then
    if verdict="$(printf '%s' "$raw_diff" | deterministic_review)"; then
      emit_degraded "$verdict"
      return 0
    fi
    emit_degraded '{"findings":[]}'
    return 0
  fi
  if printf '%s' "$raw_diff" | deterministic_review; then
    return 0
  fi

  # --- last resort: fail-open. Should be unreachable (deterministic_review
  # always returns 0), but the contract is "never hard-error, never block".
  emit_empty
  return 0
}

# Main-guard: only run the ladder when executed, not when sourced (so the bats
# suite can `source` this file and unit-test deterministic_review without the
# top-level flow consuming stdin or running).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  set -euo pipefail
  main "$@"
fi
