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
#   stdout : EXACTLY one line of JSON: {"findings":[ ... ]}  per the reviewer
#            schema below. Then exit 0. The CALLER decides block/allow; this
#            core only emits findings.
#   exit   : ALWAYS 0. FAIL-OPEN on every infra failure (no jq, claude error,
#            timeout, perl missing, unparseable LLM output) → {"findings":[]}.
#            NEVER hard-error, NEVER block on infra. Blocking is the caller's job.
#
#   LADDER (first that works wins):
#     rung 1: $CODE_REVIEWER_CMD set + resolvable → exec it (operator override),
#             passing the untouched stdin through.
#     rung 2: `claude` on PATH → one-turn LLM reviewer (verified invocation),
#             unless $TRELLIS_REVIEW_IN_PROGRESS==1 already (recursion guard).
#     rung 3: deterministic regex fallback (ALWAYS available) — committed-secret
#             criticals + left-in-debugger important. Conservative by design:
#             false criticals cause false hard-blocks downstream.
#
#   env vars:
#     CODE_REVIEWER_CMD          — operator override (rung 1). PATH name or path.
#     TRELLIS_REVIEW_IN_PROGRESS — fork-bomb sentinel. ==1 on entry → skip rung 2.
#                                  Exported =1 before the claude call so the
#                                  child's Stop hook does not re-fire review.
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
#   If perl is absent we run the command WITHOUT a wall-clock cap and rely on the
#   caller's --max-turns 1 + --max-budget-usd to bound it.
# ---------------------------------------------------------------------------
run_with_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $secs = shift @ARGV;
      my $pid = fork();
      if (!defined $pid) { exec @ARGV; }                 # fork failed → best effort
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
# emit_empty — the literal fail-open verdict. Never uses jq (jq may be absent).
# ---------------------------------------------------------------------------
emit_empty() {
  printf '%s\n' '{"findings":[]}'
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
#   re-emit it compact (one line). If not salvageable → return 1 (caller falls
#   through to rung 3 / empty). With jq: strict validation + compaction. Without
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
    out="$(printf '%s' "$text" | jq -ces '[ .[] | select(type=="object" and (.findings|type=="array")) | {findings: .findings} ] | (.[0] // empty)' 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
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
  local envelope="$1" prompt raw norm
  prompt="$(read_reviewer_prompt || true)"
  [ -n "$prompt" ] || return 1

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

  # --- rung 2: LLM reviewer, unless the recursion guard is already tripped or
  # claude is absent. Any failure falls through to rung 3.
  if [ "${TRELLIS_REVIEW_IN_PROGRESS:-0}" != "1" ] && command -v claude >/dev/null 2>&1; then
    local verdict
    if verdict="$(llm_review "$INPUT")"; then
      # Uniform framing with rung 3 / emit_empty: exactly one newline-terminated
      # line. ($() stripped any trailing newline from $verdict, so add one back.)
      printf '%s\n' "$verdict"
      return 0
    fi
    # else: fall through to the deterministic rung.
  fi

  # --- rung 3: deterministic fallback (always available). Scan the DECODED
  # diff (envelope .diff if JSON, else the whole input as a raw diff).
  local raw_diff
  raw_diff="$(extract_raw_diff "$INPUT" || true)"
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
