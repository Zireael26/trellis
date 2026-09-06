#!/usr/bin/env bash
# Gate 2: Secrets scan over the diff range.
# Usage: check-secrets.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

# Patterns: name|regex (regex evaluated with grep -E on the diff added-lines stream)
PATTERNS=(
  "AWS access key|AKIA[0-9A-Z]{16}"
  "AWS secret|aws_secret_access_key[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9/+=]{40}"
  "Generic API key|(api[_-]?key|secret[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9_-]{20,}['\"]"
  "Private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "GitHub token (ghp)|ghp_[A-Za-z0-9]{36}"
  "GitHub PAT|github_pat_[A-Za-z0-9_]{82}"
  "Slack token|xox[baprs]-[A-Za-z0-9-]{10,}"
  "Stripe live key|sk_live_[A-Za-z0-9]{24,}"
  "Anthropic key|sk-ant-[A-Za-z0-9_-]{40,}"
  "OpenAI key|sk-[A-Za-z0-9]{48}"
  "DB connection w/ password|(postgres|postgresql|mysql|mongodb|redis)://[^:@/]+:[^@/]+@"
)

# Allowlist (optional)
ALLOWLIST="$PROJECT_DIR/.claude/skills/process-gate/secrets-allowlist.txt"
ALLOW_ENTRIES=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf "%s" "$line" | awk '{$1=$1};1')"
    [ -z "$line" ] && continue
    ALLOW_ENTRIES+=("$line")
  done < "$ALLOWLIST"
fi

is_allowed() {
  local file="$1" hit="$2"
  local entry pat
  # Iterate via the `${arr[@]+...}` expansion so bash 3.2 (macOS default)
  # does not trip its empty-array + set -u bug. Without this guard, a project
  # with no allowlist file crashes here before any finding can be emitted.
  for entry in ${ALLOW_ENTRIES[@]+"${ALLOW_ENTRIES[@]}"}; do
    pat="${entry#*:}"
    epath="${entry%%:*}"
    if [ "$file" = "$epath" ] && printf "%s" "$hit" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

# .env-style file blocklist
worst="pass"
findings=()

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    .env|.env.*|*.pem|*.key|*.keystore|*.p12|*.pfx|*/secrets/*)
      # .env.example with placeholder values is a special case: pattern scan handles it.
      if [ "$f" != ".env.example" ] && ! [[ "$f" == *.example ]] && ! [[ "$f" == *.sample ]] && ! [[ "$f" == *.template ]]; then
        findings+=("$f: secret-bearing path committed")
        worst="fail"
      fi
      ;;
  esac
done < <(pg_diff_files "$RANGE")

# Pattern scan over added lines.
#
# Invariant: added-line lookup is built in one awk pass (file<TAB>lineno<TAB>content);
# each pattern hit resolves its location via a single tab-delimited content-column lookup.
# See secrets tests for file:line locator coverage.
# SAFETY: the first form creates the required private file where template-free mktemp is supported; BSD mktemp requires the -t fallback.
LOOKUP="$(mktemp 2>/dev/null || mktemp -t check-secrets)"
# Preserve $? so the trap does not mask a non-zero exit from the script body.
# shellcheck disable=SC2154  # `rc` is assigned inside the trap, which shellcheck cannot see
trap 'rc=$?; rm -f "$LOOKUP"; exit "$rc"' EXIT

# Invariant: diff failure must never be reported as an empty clean scan; unresolvable
# range or misrouted repository aborts with a preflight failure. Capture exit status before lookup.
# SAFETY: the first form creates the required private file where template-free mktemp is supported; BSD mktemp requires the -t fallback.
_cs_diff_err="$(mktemp 2>/dev/null || mktemp -t check-secrets-err)"
# `if !` rather than a bare call: under `set -e` a failing git aborts the script
# before the diagnostic below can run, which fails closed but says nothing.
# `|| _cs_diff_rc=$?` rather than `if ! ...; then _cs_diff_rc=$?`: inside the
# then-branch of `if !`, `$?` is the negation's status (0), not git's.
_cs_diff_rc=0
git diff --no-color --unified=0 "$RANGE" 2>"$_cs_diff_err" > /dev/null || _cs_diff_rc=$?
if [ "$_cs_diff_rc" -ne 0 ]; then
  printf 'check-secrets: could not resolve the diff for range %s (git exit %s) — refusing to report a verdict\n' \
    "$RANGE" "$_cs_diff_rc" >&2
  sed 's/^/check-secrets: git: /' "$_cs_diff_err" >&2
  rm -f "$_cs_diff_err"
  pg_log fail "Secrets (range=$RANGE): diff unresolvable; scan did not run"
  exit 1
fi
rm -f "$_cs_diff_err"

_cs_lookup_pipeline_rc=0
git diff --no-color --unified=0 "$RANGE" \
  | awk 'BEGIN{file=""; line=0} \
      /^\+\+\+ b\// {file=substr($0,7); next} \
      /^@@ / {match($0, /\+[0-9]+/); line=substr($0,RSTART+1,RLENGTH-1)+0; next} \
      /^\+/ && !/^\+\+\+/ {printf "%s\t%d\t%s\n", file, line, substr($0,2); line++}' \
  > "$LOOKUP" || _cs_lookup_pipeline_rc=$?
if [ "$_cs_lookup_pipeline_rc" -ne 0 ]; then
  printf 'check-secrets: could not build the added-line lookup for range %s (pipeline exit %s) — refusing to report a verdict\n' \
    "$RANGE" "$_cs_lookup_pipeline_rc" >&2
  pg_log fail "Secrets (range=$RANGE): lookup failed; scan did not run"
  exit 1
fi

_cs_lookup_parse_rc=0
added_lines="$(awk -F'\t' '{print "+"$3}' "$LOOKUP")" || _cs_lookup_parse_rc=$?
if [ "$_cs_lookup_parse_rc" -ne 0 ]; then
  printf 'check-secrets: could not parse the added-line lookup for range %s (awk exit %s) — refusing to report a verdict\n' \
    "$RANGE" "$_cs_lookup_parse_rc" >&2
  pg_log fail "Secrets (range=$RANGE): lookup parse failed; scan did not run"
  exit 1
fi

if [ -n "$added_lines" ]; then
  while IFS='|' read -r name regex; do
    # Use `--` so patterns that start with `-` don't get parsed as flags by BSD grep
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      # Resolve file:line via fixed-string lookup against the content column.
      # First match wins to preserve prior behavior.
      loc="$(awk -F'\t' -v h="$hit" 'index($3, h) {print $1":"$2; exit}' "$LOOKUP")"
      file="${loc%%:*}"
      lineno="${loc##*:}"
      if [ -n "${file:-}" ] && is_allowed "$file" "$hit"; then
        continue
      fi
      findings+=("${file:-?}:${lineno:-?} — $name")
      worst="fail"
    done < <(printf "%s" "$added_lines" | grep -oE -- "$regex" | sort -u)
  done < <(printf "%s\n" "${PATTERNS[@]}")
fi

case "$worst" in
  pass) pg_log pass "Secrets (range=$RANGE)" ;;
  warn) pg_log warn "Secrets (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Secrets (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
