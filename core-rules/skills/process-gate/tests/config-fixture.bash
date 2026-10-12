# Shared fixture for the gate-config integrity suites (config-*.bats).
# shellcheck disable=SC2034  # variables are read by the suites that load this file
#
# A throwaway skill dir holds the real run-all.sh, lib/common.sh,
# lib/diff-base.sh (spec 067's resolver) and (when it exists)
# lib/validator-env.sh, plus stub rows; use_real swaps in a real row.
# A fixture repo with one empty commit on main is the project. gh is a stub
# that serves RAW JSON from $GH_STUB_DIR and applies the caller's --jq filter
# with jq, so run-all's own filters (head, open state, dismissed reviews,
# truncation) are what decide. Secret-shaped values are assembled at runtime.

config_fixture_setup() {
  REAL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  STUB="$(mktemp -d "$BATS_TEST_TMPDIR/process-gate.XXXXXX")"
  mkdir -p "$STUB/scripts/lib" "$STUB/bin"
  cp "$REAL_SCRIPTS/run-all.sh"    "$STUB/scripts/run-all.sh"
  cp "$REAL_SCRIPTS/lib/common.sh" "$STUB/scripts/lib/common.sh"
  cp "$REAL_SCRIPTS/lib/diff-base.sh" "$STUB/scripts/lib/diff-base.sh"
  if [ -f "$REAL_SCRIPTS/lib/validator-env.sh" ]; then
    cp "$REAL_SCRIPTS/lib/validator-env.sh" "$STUB/scripts/lib/validator-env.sh"
  fi
  chmod +x "$STUB/scripts/run-all.sh"

  local name
  for name in check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh \
    check-docs.sh check-security-diff.sh check-analyze.sh; do
    printf '#!/usr/bin/env bash\necho "[stub:%s] ran"\nexit 0\n' "$name" > "$STUB/scripts/$name"
    chmod +x "$STUB/scripts/$name"
  done
  printf '#!/usr/bin/env bash\necho "info Anti-slop: n/a — posture off or undeclared"\n' \
    > "$STUB/scripts/check-slop.sh"
  chmod +x "$STUB/scripts/check-slop.sh"

  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  GH_STUB_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$GH_STUB_DIR"
  printf '{"owner":{"login":"repo-owner"}}\n' > "$GH_STUB_DIR/repo.json"
  printf '[]\n' > "$GH_STUB_DIR/prs.json"
  cat > "$STUB/bin/gh" <<'SH'
#!/usr/bin/env bash
# Raw-JSON gh: honours --limit (default 30, as gh does) and --jq/-q.
printf '%s\n' "$*" >> "$GH_LOG"
filter="" limit=30 json="" args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq|-q) filter="${args[i + 1]}" ;;
    --limit|-L) limit="${args[i + 1]}" ;;
  esac
done
case "$1 $2" in
  "repo view") json="$(cat "$GH_STUB_DIR/repo.json")" || exit 1 ;;
  "pr list") json="$(jq --argjson n "$limit" '.[:$n]' "$GH_STUB_DIR/prs.json")" || exit 1 ;;
  "pr view") json="$(cat "$GH_STUB_DIR/pr-$3.json" 2>/dev/null)" || exit 1 ;;
  "api"*)
    login="$(printf '%s' "$2" | sed -E 's#^repos/[^/]+/[^/]+/collaborators/([^/]+)/permission$#\1#')"
    [ -n "$login" ] && [ "$login" != "$2" ] && json="$(cat "$GH_STUB_DIR/perm-$login.json" 2>/dev/null)" || exit 1 ;;
  *) exit 1 ;;
esac
if [ -n "$filter" ]; then
  printf '%s\n' "$json" | jq -r "$filter"
else
  printf '%s\n' "$json"
fi
SH
  chmod +x "$STUB/bin/gh"
  export PATH="$STUB/bin:$PATH" GH_LOG GH_STUB_DIR

  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/project.XXXXXX")"
  git -C "$PROJECT_DIR" init -q -b main
  git -C "$PROJECT_DIR" config user.email "test@example.com"
  git -C "$PROJECT_DIR" config user.name "test"
  git -C "$PROJECT_DIR" config commit.gpgsign false
  git -C "$PROJECT_DIR" commit --allow-empty -q -m init
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
  local var
  for var in $(compgen -A variable PROCESS_GATE_); do unset "$var"; done
  unset PG_TRUSTED_ROOT PG_SKILL_ROOT PG_GATE_RANGE PG_MODE BASH_ENV ENV SECURITY_GATE_AUDIT_DIR
  export PROCESS_GATE_HEAVY_LAUNCHER="$BATS_TEST_TMPDIR/no-trellis-launcher"
  CFG=.claude/skills/process-gate-local/local.config.sh
}

# put <rel> <content>: write a project file (parents created).
put() {
  mkdir -p "$(dirname "$PROJECT_DIR/$1")"
  printf '%s' "$2" > "$PROJECT_DIR/$1"
}

commit_all() {
  git -C "$PROJECT_DIR" add -A || return 1
  git -C "$PROJECT_DIR" commit -qm "$1" || return 1
}

feature() {
  git -C "$PROJECT_DIR" switch -qc feature
}

use_real() {
  cp "$REAL_SCRIPTS/$1" "$STUB/scripts/$1"
}

head_sha() {
  git -C "$PROJECT_DIR" rev-parse HEAD
}

run_gate() {
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=$1 --range=main..HEAD"
}

# stack_config <validator>...: a base-ready config naming these validators.
stack_config() {
  local v body='PROCESS_GATE_STACK_PROFILE="custom"'$'\n''PROCESS_GATE_STACK_VALIDATORS=('$'\n'
  for v in "$@"; do body="$body  '$v'"$'\n'; done
  put "$CFG" "$body)"$'\n'
}

# probe_row <var>...: replace the check-docs stub with a row that loads config
# like every real row and writes `<var>=<value>` lines (arrays one line per
# item, `<var>#=<count>` first) to $PROBE.
probe_row() {
  PROBE="$BATS_TEST_TMPDIR/probe.txt"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"\n'
    printf '. "$SKILL_DIR/scripts/lib/common.sh"\n'
    printf 'pg_load_config "$@" || exit 1\n'
    # ${#X[@]} of a scalar trips set -u in bash; the probe only reads.
    printf 'set +u\n'
    printf ": > '%s'\n" "$PROBE"
    local v
    for v in "$@"; do
      sed -e "s/VAR/$v/g" -e "s|PROBE_FILE|$PROBE|g" <<'TEMPLATE'
n=0; [ -z "${VAR+set}" ] || n=${#VAR[@]}
printf '%s#=%s\n' VAR "$n" >> 'PROBE_FILE'
for x in ${VAR[@]+"${VAR[@]}"}; do printf '%s=%s\n' VAR "$x" >> 'PROBE_FILE'; done
TEMPLATE
    done
  } > "$STUB/scripts/check-docs.sh"
  chmod +x "$STUB/scripts/check-docs.sh"
}

# GitHub fixtures, written as the raw JSON gh would return.
gh_prs() { printf '%s\n' "$1" > "$GH_STUB_DIR/prs.json"; }
pr_row() { printf '{"number":%s,"headRefOid":"%s","state":"%s"}' "$1" "$2" "${3:-OPEN}"; }
comment() { jq -nc --arg a "$1" --arg b "$2" '{author:{login:$a},body:$b}'; }
review() { jq -nc --arg a "$1" --arg b "$2" --arg s "$3" '{author:{login:$a},body:$b,state:$s}'; }
# gh_view <number> <state> <head> <comments-json-array> [reviews-json-array]
gh_view() {
  jq -n --arg s "$2" --arg h "$3" --argjson c "$4" --argjson r "${5:-[]}" \
    '{state:$s,headRefOid:$h,comments:$c,reviews:$r}' > "$GH_STUB_DIR/pr-$1.json"
}
# gh_org <org> <repo>: the repo is organization-owned (admin approvals apply).
gh_org() {
  printf '{"owner":{"login":"%s","type":"Organization"},"nameWithOwner":"%s/%s"}\n' \
    "$1" "$1" "$2" > "$GH_STUB_DIR/repo.json"
}
# gh_perm <login> <permission>: serve this permission for the collaborators probe.
# No stub file means the lookup fails (fail closed).
gh_perm() { printf '{"permission":"%s"}\n' "$2" > "$GH_STUB_DIR/perm-$1.json"; }

# Carrier fixture: a repo whose .claude/skills/process-gate/scripts/run-all.sh
# is a stub beside the real diff-base resolver the carrier needs (spec 067),
# and one feature-branch ref line to push.
prepush_fixture() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/skills/process-gate/scripts/lib"
  cp "$REPO_ROOT/core-rules/skills/process-gate/scripts/lib/diff-base.sh" \
    "$REPO/.claude/skills/process-gate/scripts/lib/diff-base.sh"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email pre-push@test.invalid
  git -C "$REPO" config user.name pre-push-test
  git -C "$REPO" config commit.gpgsign false
  printf '/.claude/skills/process-gate/\n' > "$REPO/.git/info/exclude"
  git -C "$REPO" commit --allow-empty -qm base
  git -C "$REPO" switch -qc feature
  OLD="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" commit --allow-empty -qm change
  NEW="$(git -C "$REPO" rev-parse HEAD)"
  printf 'refs/heads/feature %s refs/heads/feature %s\n' "$NEW" "$OLD" > "$BATS_TEST_TMPDIR/refs"
}

# stub_runner <rc> [line...]: a run-all that prints these lines and exits rc.
stub_runner() {
  local runner="$REPO/.claude/skills/process-gate/scripts/run-all.sh" rc="$1" line
  shift
  printf '#!/usr/bin/env bash\n' > "$runner"
  for line in "$@"; do
    printf 'printf "%%s\\n" %q\n' "$line" >> "$runner"
  done
  printf 'exit %s\n' "$rc" >> "$runner"
}

# run_prepush <hook> [env...]
run_prepush() {
  local hook="$1"
  shift
  run env TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home" "$@" sh -c \
    'cd "$1" && sh "$2" origin https://example.invalid/repo.git < "$3"' \
    _ "$REPO" "$hook" "$BATS_TEST_TMPDIR/refs"
}
