#!/usr/bin/env bats
# The scanned range must not control its own scanner. Project-local config,
# gitleaks/OSV config and the dedupe baseline are read from the range BASE, and
# local.config.sh is parsed as data; engines are absolute PATH binaries outside
# the project, never shell functions; a range that changes gate config is
# scanned under the base copies, gets a notice at push, and at merge needs the
# repo owner's approval line naming its exact head SHA on the one open PR.
#
# The semgrep stub is a detector: it reports a high finding for the first
# target it receives, so MERGEABLE under it proves the file never reached the
# real engine. The gitleaks stub reads the range history the way gitleaks does
# and honours --config, the source tree's .gitleaks.toml / .gitleaksignore and
# --gitleaks-ignore-path, so an allowlist only wins if the gate hands it over.
# It also follows an `[extend] path` relative to its cwd, as gitleaks does. The
# OSV stub honours --config, else discovers <dir>/osv-scanner.toml. The gh stub
# serves `repo view`, `pr list` and `pr view <n>` from gh-pr-<n>.json fixtures.

setup() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT/audits" "$BIN"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR SECURITY_GATE_SHELLCHECK
  unset SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS SECURITY_GATE_SKIP PG_MODE
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export SEMGREP_MODE=detect SHELLCHECK_MODE=clean
  export SCANNER_FIXTURES="$TEST_ROOT"
  export SHELLCHECK_ARGS_LOG="$TEST_ROOT/shellcheck.args"

  # Only infrastructure commands are inherited; never a real scanner.
  for cmd in bash git basename dirname mktemp mkdir readlink ls sort tail rm head awk cat sed grep; do
    ln -s "$(command -v "$cmd")" "$BIN/$cmd"
  done
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$BIN/python3"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email "security-gate@trellis.test"
  git -C "$PROJECT" config user.name "trellis test"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-project.json"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "seed"

  cat > "$BIN/scanner" <<'SH'
#!/usr/bin/env bash
engine="$(basename "$0")"
case "$engine" in
  semgrep)
    targets=()
    for a in "$@"; do case "$a" in --*|scan) ;; *) targets+=("$a") ;; esac; done
    # Every target is reported scanned: the gate checks coverage per target.
    scanned="" sep=""
    for t in ${targets[@]+"${targets[@]}"}; do scanned="$scanned$sep\"$t\""; sep=","; done
    if [ "$SEMGREP_MODE" = detect ] && [ "${#targets[@]}" -gt 0 ]; then
      printf '{"results":[{"check_id":"detector","path":"%s","start":{"line":1},"extra":{"severity":"ERROR","message":"detector"}}],"errors":[],"paths":{"scanned":[%s]}}\n' \
        "${targets[0]}" "$scanned"
    else
      printf '{"results":[],"errors":[],"paths":{"scanned":[%s]}}\n' "$scanned"
    fi
    exit 0 ;;
  shellcheck)
    printf '%s\n' "$@" > "$SHELLCHECK_ARGS_LOG"
    if [ "$SHELLCHECK_MODE" = findings ]; then
      for a in "$@"; do case "$a" in --*) ;; *) target="$a"; break ;; esac; done
      printf '[{"file":"%s","line":1,"code":2086,"level":"error","message":"fixture"}]\n' "$target"
      exit 1
    fi
    printf '%s\n' '[]'
    exit 0 ;;
  osv-scanner)
    config="" dir=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --config) config="$2"; shift 2 ;;
        --*) shift ;;
        *) dir="$1"; shift ;;
      esac
    done
    [ -n "$config" ] || { [ -f "$dir/osv-scanner.toml" ] && config="$dir/osv-scanner.toml"; }
    # OSV's real stderr receipt for each tracked lockfile under the root.
    while IFS= read -r -d '' f; do
      case "${f##*/}" in
        package-lock.json) printf 'Scanned %s/%s file and found 1 packages\n' "$dir" "$f" >&2 ;;
      esac
    done < <(git -C "$dir" ls-files -z)
    if [ "${OSV_MODE:-clean}" = vuln ] && ! { [ -n "$config" ] && grep -q FIXTURE-HIGH "$config"; }; then
      printf '{"results":[{"source":{"path":"%s/package.json","type":"lockfile"},"packages":[{"package":{"name":"fixture","version":"1.0","ecosystem":"npm"},"groups":[],"vulnerabilities":[{"id":"FIXTURE-HIGH","summary":"seeded","database_specific":{"severity":"HIGH"}}]}]}]}\n' "$dir"
    else
      printf '%s\n' '{"results":[]}'
    fi
    exit 0 ;;
  gitleaks)
    source="" logopts="" config="" ignore="." report=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source) source="$2"; shift 2 ;;
        --log-opts=*) logopts="${1#--log-opts=}"; shift ;;
        --config) config="$2"; shift 2 ;;
        --gitleaks-ignore-path) ignore="$2"; shift 2 ;;
        --report-path) report="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    leak=0
    # shellcheck disable=SC2086  # log options are a revision range by design
    git -C "$source" log -p $logopts 2>/dev/null | grep -Eq 'ghp_[0-9A-Za-z]{36}' && leak=1
    [ -n "$config" ] || { [ -f "$source/.gitleaks.toml" ] && config="$source/.gitleaks.toml"; }
    if [ -n "$config" ] && grep -q '^\[allowlist\]' "$config"; then leak=0; fi
    # gitleaks (via Viper) case-folds keys, and TOML allows quoted and dotted keys.
    ext="$(sed -n -E 's/^([Ee][Xx][Tt][Ee][Nn][Dd]\.)?"?[Pp][Aa][Tt][Hh]"?[[:space:]]*=[[:space:]]*"(.*)"$/\2/p' "$config" 2>/dev/null)"
    if [ -n "$ext" ] && [ -f "$ext" ] && grep -q '^\[allowlist\]' "$ext"; then leak=0; fi
    for ig in "$source/.gitleaksignore" "$ignore/.gitleaksignore" "$ignore"; do
      if [ -f "$ig" ] && [ -s "$ig" ]; then leak=0; fi
    done
    if [ "$leak" -eq 1 ]; then
      printf '%s\n' '[{"RuleID":"github-pat","Description":"GitHub PAT","File":"cfg.txt","StartLine":1,"Commit":"abc12345"}]' > "$report"
      exit 1
    fi
    printf '%s\n' '[]' > "$report"
    exit 0 ;;
  gh)
    case "$1 $2" in
      "repo view")
        [ "${GH_REPO_MODE:-ok}" = ok ] || exit 1
        printf '{"owner":{"login":"%s"},"nameWithOwner":"%s/project"}\n' "${GH_OWNER-owner}" "${GH_OWNER-owner}"
        exit 0 ;;
      "pr list")
        [ "${GH_MODE:-ok}" = ok ] || exit 1
        if [ -f "$SCANNER_FIXTURES/gh-list.json" ]; then cat "$SCANNER_FIXTURES/gh-list.json"; exit 0; fi
        sep=""
        printf '['
        for f in "$SCANNER_FIXTURES"/gh-pr-*.json; do
          [ -e "$f" ] || continue
          printf '%s' "$sep"; cat "$f"; sep=","
        done
        printf ']\n'
        exit 0 ;;
      "pr view")
        [ "${GH_MODE:-ok}" = ok ] || exit 1
        [ "${GH_VIEW_MODE:-ok}" = ok ] || exit 1
        f="$SCANNER_FIXTURES/gh-view-$3.json"
        [ -f "$f" ] || f="$SCANNER_FIXTURES/gh-pr-$3.json"
        [ -f "$f" ] || exit 1
        cat "$f"
        exit 0 ;;
    esac
    exit 1 ;;
esac
exit 99
SH
  chmod +x "$BIN/scanner"
  for engine in semgrep gitleaks osv-scanner shellcheck gh; do
    ln -s scanner "$BIN/$engine"
  done
  SCRIPT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CFG_DIR="$PROJECT/.claude/skills/security-gate-local"
  RANGE_SPEC="HEAD~1..HEAD"
  DIFF_ARGS=()
  # Composed at runtime so this file never carries a token-shaped literal.
  TOKEN="ghp_$(printf '%s' 0123456789abcdefghij ABCDEFGHIJ 012345)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

commit_all() {
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "${1:-change}"
}

change_ts() {
  printf '%s\n' 'export const changed = true;' > "$PROJECT/changed.ts"
}

write_config() {
  mkdir -p "$CFG_DIR"
  printf '%s\n' "$@" > "$CFG_DIR/local.config.sh"
}

head_sha() {
  git -C "$PROJECT" rev-parse HEAD
}

# add_pr <number> <state> <headRefOid> <base> [<author> <comment body>]
add_pr() {
  local comments="[]"
  [ -z "${6:-}" ] || comments="[{\"author\":{\"login\":\"$5\"},\"body\":\"$6\"}]"
  printf '{"number":%s,"state":"%s","headRefOid":"%s","baseRefName":"%s","url":"https://example.invalid/pull/%s","comments":%s,"reviews":[]}\n' \
    "$1" "$2" "$3" "$4" "$1" "$comments" > "$TEST_ROOT/gh-pr-$1.json"
}

# run_diff_at <cwd> <PATH> [VAR=value...]: run-diff from a chosen cwd and PATH,
# the way pre-push runs it from the repository root.
run_diff_at() {
  local cwd="$1" path="$2"
  shift 2
  run env PATH="$path" SECURITY_GATE_STACK_PROFILE=web-next \
    SECURITY_GATE_PROJECT_NAME=project "$@" \
    bash -c 'cd "$1" || exit 99; shift; exec bash "$@"' run-diff-at "$cwd" \
    "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range="$RANGE_SPEC" --no-llm \
    ${DIFF_ARGS[@]+"${DIFF_ARGS[@]}"}
}

run_diff() {
  run env PATH="$BIN" SECURITY_GATE_STACK_PROFILE=web-next \
    SECURITY_GATE_PROJECT_NAME=project "$@" \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range="$RANGE_SPEC" --no-llm \
    ${DIFF_ARGS[@]+"${DIFF_ARGS[@]}"}
}

assert_blocked_by() {
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$1"* ]] || { echo "missing: $1"; echo "$output"; false; }
}

assert_mergeable() {
  [ "$status" -eq 0 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
}

push_notice() {
  printf 'security config changed in range: scanned with BASE config; merge requires gate-config-approved: %s' "$1"
}

# --- range-authored config cannot steer the scan -------------------------

@test "a semgrep() function added to local.config.sh in the range never replaces the engine" {
  write_config \
    "semgrep() { : > \"$TEST_ROOT/pwned\"; printf '%s\\n' '{\"results\":[],\"errors\":[],\"paths\":{\"scanned\":[\"x\"]}}'; }"
  change_ts
  commit_all
  run_diff
  assert_blocked_by "semgrep/detector"
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "a PATH prepend added to local.config.sh in the range never reaches the engines" {
  mkdir -p "$PROJECT/.tools"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\nprintf "%%s\\n" %s\n' "$TEST_ROOT" \
    "'{\"results\":[],\"errors\":[],\"paths\":{\"scanned\":[\"x\"]}}'" > "$PROJECT/.tools/semgrep"
  chmod +x "$PROJECT/.tools/semgrep"
  write_config "PATH=\"$PROJECT/.tools:\$PATH\""
  change_ts
  commit_all
  run_diff
  assert_blocked_by "semgrep/detector"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "SECURITY_GATE_SHELLCHECK=0 set by the range does not switch ShellCheck off" {
  write_config 'SECURITY_GATE_SHELLCHECK=0'
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/changed.sh"
  commit_all
  run_diff SECURITY_GATE_STACK_PROFILE=shell-tooling SEMGREP_MODE=clean SHELLCHECK_MODE=findings
  assert_blocked_by "shellcheck/SC2086"
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "a .gitleaks.toml allowlist added by the range does not hide a token in the range" {
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  printf '[allowlist]\npaths = [".*"]\n' > "$PROJECT/.gitleaks.toml"
  commit_all
  run_diff
  assert_blocked_by "gitleaks/github-pat"
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "a .gitleaksignore added by the range does not hide a token in the range" {
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  printf 'abc12345:cfg.txt:github-pat:1\n' > "$PROJECT/.gitleaksignore"
  commit_all
  run_diff
  assert_blocked_by "gitleaks/github-pat"
}

# --- the base config is data ----------------------------------------------

@test "a base-tree config with a function definition is BLOCKED as not data" {
  write_config 'SECURITY_GATE_STACK_PROFILE="web-next"' \
    "semgrep() { printf '%s\\n' '{\"results\":[],\"errors\":[],\"paths\":{\"scanned\":[\"x\"]}}'; }"
  commit_all "base config"
  change_ts
  commit_all
  run_diff
  assert_blocked_by "security-gate local config is not data"
}

@test "a base-tree config with a command substitution is BLOCKED as not data" {
  write_config 'SECURITY_GATE_AUDIT_DIR="$(printf audits)"'
  commit_all "base config"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security-gate local config is not data"
}

@test "a pre-existing base-tree DATA config is honoured from the base, not the worktree" {
  write_config \
    '# shellcheck shell=bash disable=SC2034' \
    'SECURITY_GATE_STACK_PROFILE="shell-tooling"' \
    'SECURITY_GATE_PROJECT_NAME="${SECURITY_GATE_PROJECT_NAME:-project}"' \
    '' \
    'SECURITY_GATE_SHELLCHECK="1"   # opt in' \
    "SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS='vendor/*'" \
    'LLM_PROVIDER="none"'
  commit_all "base config"
  mkdir -p "$PROJECT/vendor"
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/changed.sh"
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/vendor/skip.sh"
  commit_all
  # Uncommitted: the worktree tries to switch ShellCheck off after the fact.
  printf 'SECURITY_GATE_SHELLCHECK="0"\n' >> "$CFG_DIR/local.config.sh"
  run_diff SEMGREP_MODE=clean SHELLCHECK_MODE=findings
  assert_blocked_by "shellcheck/SC2086"
  [[ "$output" != *"not data"* ]] || { echo "$output"; false; }
  grep -q 'changed.sh$' "$SHELLCHECK_ARGS_LOG"
  ! grep -q 'vendor/skip.sh' "$SHELLCHECK_ARGS_LOG"
}

@test "an exported semgrep function in the environment is ignored" {
  change_ts
  commit_all
  run_diff "BASH_FUNC_semgrep%%=() { printf '%s\\n' '{\"results\":[],\"errors\":[],\"paths\":{\"scanned\":[\"x\"]}}'; }"
  assert_blocked_by "semgrep/detector"
}

@test "a range with no derivable base is BLOCKED" {
  change_ts
  commit_all
  RANGE_SPEC="HEAD"
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "range base"
}

# --- push mode: notice, normal verdict ------------------------------------

@test "push mode: a config change prints the notice and keeps the normal verdict" {
  printf 'build/\n' > "$PROJECT/.semgrepignore"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "push mode: a non-ASCII path under security-gate-local is a config change" {
  mkdir -p "$CFG_DIR"
  printf 'x\n' > "$CFG_DIR/"$'\xc3\xa9'".sh"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

# --- merge mode: PR approval line naming the exact head SHA ---------------

@test "merge mode: a config change with no approval is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"has no 'gate-config-approved:"* ]] || { echo "$output"; false; }
}

@test "merge mode: an approval line for the wrong SHA is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(git -C "$PROJECT" rev-parse HEAD~1)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"has no repo-owner approval of head"* ]] || { echo "$output"; false; }
}

@test "merge mode: an approval line for the head SHA proceeds and is quoted" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "LGTM\\ngate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"gate-config-approved: $(head_sha)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"@owner"* ]] || { echo "$output"; false; }
}

@test "merge mode: a PR whose head is not the range head is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(git -C "$PROJECT" rev-parse HEAD~1)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"0 open PRs have head"* ]] || { echo "$output"; false; }
}

@test "merge mode: gh unavailable fails closed" {
  rm "$BIN/gh"
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"gh unavailable"* ]] || { echo "$output"; false; }
}

@test "merge mode: gh failing to identify the PR fails closed" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_MODE=fail
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"could not list the open PRs"* ]] || { echo "$output"; false; }
}

@test "CONTROL merge mode without a config change needs no gh" {
  rm "$BIN/gh"
  change_ts
  commit_all
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" != *"security config changed"* ]] || { echo "$output"; false; }
}

@test "the process-gate adapter passes merge mode through to run-diff" {
  rm "$BIN/gh"
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  run env PATH="$BIN" CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT" \
    SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    SEMGREP_MODE=clean PG_MODE=merge \
    bash "$SCRIPT_ROOT/../process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  assert_blocked_by "security config changed: needs human review"
}

# --- round 2: approval identity -------------------------------------------

@test "merge mode: an approval line from a login that is not the repo owner is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main mallory "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_OWNER=owner
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"@mallory"* ]] || { echo "$output"; false; }
}

@test "merge mode: an unreadable repo owner fails closed" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_REPO_MODE=fail
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"could not read the repository owner"* ]] || { echo "$output"; false; }
}

@test "merge mode: two open PRs with the same head and different bases are BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  add_pr 8 OPEN "$(head_sha)" release owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "2 open PRs have head"
  [[ "$output" == *"exactly one is required)"* ]] || { echo "$output"; false; }
  [[ "$output" != *"could not read PR"* ]] || { echo "$output"; false; }
}

@test "CONTROL merge mode: a closed PR with the same head is not counted" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 6 CLOSED "$(head_sha)" release owner "gate-config-approved: $(head_sha)"
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"on PR #7"* ]] || { echo "$output"; false; }
}

@test "merge mode: an approval only on a closed PR is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 6 CLOSED "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "0 open PRs have head"
}

@test "a direct push to main that changes gate config is BLOCKED (merge mode, no PR)" {
  rm -f "$TEST_ROOT"/gh-pr-*.json
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  run env PATH="$BIN" CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT" \
    SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    SEMGREP_MODE=clean PG_MODE=merge \
    bash "$SCRIPT_ROOT/../process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD
  assert_blocked_by "security config changed: needs human review"
}

@test "merge mode without --range refuses instead of deriving one" {
  change_ts
  commit_all
  run env PATH="$BIN" SECURITY_GATE_PROJECT_NAME=project SEMGREP_MODE=clean \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --mode=merge --no-llm
  assert_blocked_by "merge mode requires --range/--base"
}

@test "merge mode: a zero-commit range whose net diff deletes config still needs approval" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  commit_all "base config"
  # Base = the config commit, head = its parent: no commits, one deletion.
  RANGE_SPEC="HEAD..HEAD~1"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
}

# --- round 2: OSV config ----------------------------------------------------

@test "an osv-scanner.toml added by the range does not waive an advisory in the range" {
  printf '[[IgnoredVulns]]\nid = "FIXTURE-HIGH"\n' > "$PROJECT/osv-scanner.toml"
  printf '%s\n' '{"dependencies":{"fixture":"1.0"}}' > "$PROJECT/package.json"
  commit_all
  run_diff SEMGREP_MODE=clean OSV_MODE=vuln
  assert_blocked_by "osv/FIXTURE-HIGH"
  [[ "$output" == *"osv-scanner.toml"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "merge mode: an osv-scanner.toml change needs approval" {
  printf '# no ignores\n' > "$PROJECT/osv-scanner.toml"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
}

@test "CONTROL a base-tree osv-scanner.toml is honoured" {
  printf '[[IgnoredVulns]]\nid = "FIXTURE-HIGH"\n' > "$PROJECT/osv-scanner.toml"
  commit_all "base osv config"
  printf '%s\n' '{"dependencies":{"fixture":"1.0"}}' > "$PROJECT/package.json"
  # The changed manifest needs a lockfile OSV reads, or the scan is incomplete.
  printf '%s\n' '{"lockfileVersion":3,"packages":{}}' > "$PROJECT/package-lock.json"
  commit_all
  run_diff SEMGREP_MODE=clean OSV_MODE=vuln
  assert_mergeable
}

# --- round 2: gitleaks [extend] path ----------------------------------------

@test "a base .gitleaks.toml that extends a file is refused, so a range edit of the extension cannot hide a token" {
  printf '[extend]\npath = "common.toml"\n' > "$PROJECT/.gitleaks.toml"
  printf '# shared rules\n' > "$PROJECT/common.toml"
  commit_all "base gitleaks config"
  printf '[allowlist]\npaths = [".*"]\n' > "$PROJECT/common.toml"
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff_at "$PROJECT" "$BIN"
  assert_blocked_by "[extend] path"
}

# --- round 2: baseline from the base ----------------------------------------

poison_baseline() {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[{"tool":"gitleaks","rule":"github-pat","file":"cfg.txt","line":1}],"historical_findings":[]}' \
    > "$PROJECT/audits/$1-baseline-project.json"
}

@test "a poisoned baseline added in the range does not dedupe a leak, and is a config change" {
  poison_baseline 9999-12-31
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff
  assert_blocked_by "gitleaks/github-pat"
  [[ "$output" == *"audits/9999-12-31-baseline-project.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "a baseline modified in the range does not dedupe a leak" {
  poison_baseline 2026-01-01
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff
  assert_blocked_by "gitleaks/github-pat"
}

@test "merge mode: a poisoned baseline in the range needs approval and still does not dedupe" {
  poison_baseline 9999-12-31
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *"gitleaks/github-pat"* ]] || { echo "$output"; false; }
}

@test "CONTROL push mode: a clean baseline update gets the notice and the normal verdict" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-02-01-baseline-project.json"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "a base without a baseline BLOCKS even when the range adds one" {
  git -C "$PROJECT" rm -q audits/2026-01-01-baseline-project.json
  commit_all "drop baseline"
  # git rm removed the now-empty audits/ dir with its last file.
  mkdir -p "$PROJECT/audits"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-project.json"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "no baseline JSON found"
  [[ "$output" != *"bash "*"run-baseline.sh"* ]] || { echo "$output"; false; }
}

# --- round 2: PATH binary shadowing -----------------------------------------

fake_project_semgrep() {
  mkdir -p "$PROJECT/.tools"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\nprintf "%%s\\n" %s\n' "$TEST_ROOT" \
    "'{\"results\":[],\"errors\":[],\"paths\":{\"scanned\":[\"x\"]}}'" > "$PROJECT/.tools/semgrep"
  chmod +x "$PROJECT/.tools/semgrep"
}

@test "an inherited relative PATH entry cannot supply an engine" {
  fake_project_semgrep
  change_ts
  commit_all
  run_diff_at "$PROJECT" ".tools:$BIN"
  assert_blocked_by "semgrep/detector"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "a PATH directory inside the project cannot supply an engine" {
  fake_project_semgrep
  change_ts
  commit_all
  run_diff_at "$TEST_ROOT" "$PROJECT/.tools:$BIN"
  assert_blocked_by "semgrep/detector"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "an engine symlinked into the project is refused" {
  fake_project_semgrep
  mkdir -p "$TEST_ROOT/linkbin"
  ln -s "$PROJECT/.tools/semgrep" "$TEST_ROOT/linkbin/semgrep"
  change_ts
  commit_all
  run_diff_at "$TEST_ROOT" "$TEST_ROOT/linkbin:$BIN"
  assert_blocked_by "semgrep resolves inside the scanned project"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "an exported type function cannot steer engine resolution" {
  fake_project_semgrep
  change_ts
  commit_all
  run_diff "BASH_FUNC_type%%=() { if [ \"\$2\" = semgrep ]; then printf '%s\\n' \"$PROJECT/.tools/semgrep\"; else builtin type \"\$@\"; fi; }"
  assert_blocked_by "semgrep/detector"
  [ ! -e "$TEST_ROOT/pwned" ]
}

# --- round 2: parser vectors ------------------------------------------------

assert_config_not_data() {
  write_config "$@"
  commit_all "base config"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security-gate local config is not data"
}

@test "not data: a backtick command substitution" {
  assert_config_not_data 'SECURITY_GATE_AUDIT_DIR="`printf audits`"'
}

@test "not data: a nested default expansion" {
  assert_config_not_data 'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:-${HOME}}"'
}

@test "not data: an assigning default expansion" {
  assert_config_not_data 'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR:=audits}"'
}

@test "not data: a pattern-stripping expansion" {
  assert_config_not_data 'SECURITY_GATE_AUDIT_DIR="${SECURITY_GATE_AUDIT_DIR#x}"'
}

@test "not data: a plain variable reference" {
  assert_config_not_data 'SECURITY_GATE_AUDIT_DIR=$SECURITY_GATE_PROJECT_NAME'
}

@test "not data: a default that names another key" {
  assert_config_not_data 'SECURITY_GATE_SHELLCHECK="${SECURITY_GATE_SKIP:-0}"'
}

@test "not data: export" {
  assert_config_not_data 'export SECURITY_GATE_SHELLCHECK=1'
}

@test "not data: an array" {
  assert_config_not_data 'SECURITY_GATE_SHELLCHECK_EXCLUDE_GLOBS=(vendor/* build/*)'
}

@test "not data: Unicode lookalike quotes" {
  assert_config_not_data 'SECURITY_GATE_SHELLCHECK=“0”'
}

@test "not data: an LLM_* line with a command substitution" {
  assert_config_not_data 'LLM_PROVIDER="$(printf none)"'
}

@test "CRLF line endings are accepted and the values honoured" {
  write_config $'SECURITY_GATE_STACK_PROFILE="web-next"\r' $'SECURITY_GATE_SHELLCHECK="1"\r'
  commit_all "base config"
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/changed.sh"
  commit_all
  run_diff SEMGREP_MODE=clean SHELLCHECK_MODE=findings
  assert_blocked_by "shellcheck/SC2086"
  [[ "$output" != *"not data"* ]] || { echo "$output"; false; }
}

@test "a duplicate key is last-wins" {
  write_config 'SECURITY_GATE_SHELLCHECK="0"' 'SECURITY_GATE_SHELLCHECK="1"'
  commit_all "base config"
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/changed.sh"
  commit_all
  run_diff SEMGREP_MODE=clean SHELLCHECK_MODE=findings
  assert_blocked_by "shellcheck/SC2086"
}

@test "A...B reads config from the merge base, not either endpoint" {
  git -C "$PROJECT" branch -M main
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  commit_all "base config"
  git -C "$PROJECT" checkout -q -b feature
  write_config 'SECURITY_GATE_SHELLCHECK="0"'
  printf '#!/usr/bin/env bash\necho $1\n' > "$PROJECT/changed.sh"
  commit_all "feature"
  git -C "$PROJECT" checkout -q main
  write_config 'SECURITY_GATE_SHELLCHECK="0"'
  commit_all "main moves on"
  git -C "$PROJECT" checkout -q feature
  RANGE_SPEC="main...feature"
  run_diff SEMGREP_MODE=clean SHELLCHECK_MODE=findings
  assert_blocked_by "shellcheck/SC2086"
}

# --- B0-6: .pi/** is gate config ------------------------------------------

@test "push mode: adding .pi/subagents.json gets the notice and the normal verdict" {
  mkdir -p "$PROJECT/.pi"
  printf '{}\n' > "$PROJECT/.pi/subagents.json"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *".pi/subagents.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "merge mode: modifying .pi/extensions/x.ts without approval is BLOCKED" {
  mkdir -p "$PROJECT/.pi/extensions"
  printf '%s\n' 'export const x = 1;' > "$PROJECT/.pi/extensions/x.ts"
  commit_all "base pi extension"
  printf '%s\n' 'export const x = 2;' > "$PROJECT/.pi/extensions/x.ts"
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *".pi/extensions/x.ts"* ]] || { echo "$output"; false; }
}

@test "merge mode: deleting .pi/agents/a.md without approval is BLOCKED" {
  mkdir -p "$PROJECT/.pi/agents"
  printf '# agent\n' > "$PROJECT/.pi/agents/a.md"
  commit_all "base pi agent"
  git -C "$PROJECT" rm -q .pi/agents/a.md
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
  [[ "$output" == *".pi/agents/a.md"* ]] || { echo "$output"; false; }
}

@test "merge mode: a .pi change with the owner's approval of the head proceeds" {
  mkdir -p "$PROJECT/.pi"
  printf '{}\n' > "$PROJECT/.pi/subagents.json"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"gate-config-approved: $(head_sha)"* ]] || { echo "$output"; false; }
}

# --- round 3 (security re-review R1–R7) -------------------------------------

# R1: the extension refusal must match what gitleaks honours.
extend_attack() {
  printf '%b' "$1" > "$PROJECT/.gitleaks.toml"
  printf '# shared rules\n' > "$PROJECT/common.toml"
  commit_all "base gitleaks config"
  printf '[allowlist]\npaths = [".*"]\n' > "$PROJECT/common.toml"
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff_at "$PROJECT" "$BIN"
}

@test "R1: a mixed-case [Extend] Path is refused" {
  extend_attack '[Extend]\nPath = "common.toml"\n'
  assert_blocked_by "[extend] path"
}

@test "R1: a quoted \"path\" key is refused" {
  extend_attack '[extend]\n"path" = "common.toml"\n'
  assert_blocked_by "[extend] path"
}

@test "R1: a dotted extend.Path key is refused" {
  extend_attack 'extend.Path = "common.toml"\n'
  assert_blocked_by "[extend] path"
}

@test "R1: without tomllib a base .gitleaks.toml cannot be verified and BLOCKS" {
  real="$(readlink "$BIN/python3")"
  rm "$BIN/python3"
  cat > "$BIN/python3" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-" ]; then
    { printf 'import sys\nsys.modules["tomllib"] = None\n'; cat; } | "$real" "\$@"
    exit \$?
  fi
done
exec "$real" "\$@"
SH
  chmod +x "$BIN/python3"
  printf '[allowlist]\ndescription = "base"\n' > "$PROJECT/.gitleaks.toml"
  commit_all "base gitleaks config"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "cannot verify"
}

@test "R1 CONTROL: [extend] useDefault is allowed and the token is found" {
  printf '[extend]\nuseDefault = true\n' > "$PROJECT/.gitleaks.toml"
  commit_all "base gitleaks config"
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff
  assert_blocked_by "gitleaks/github-pat"
  [[ "$output" != *"[extend] path"* ]] || { echo "$output"; false; }
}

# R2: gate-owned Python never imports modules from the scanned tree.
@test "R2: a root json.py in the range cannot silence the gitleaks parser" {
  printf 'import sys\nsys.exit(0)\n' > "$PROJECT/json.py"
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff_at "$PROJECT" "$BIN" SEMGREP_MODE=clean
  assert_blocked_by "gitleaks/github-pat"
}

# R3: an explicit --baseline is a repository path read from the base. Callers
# run from the repository root, so a relative path is tried from there.
@test "R3: an explicit --baseline poisoned in the range does not dedupe, and is a config change" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' > "$PROJECT/audits/current.json"
  commit_all "base explicit baseline"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[{"tool":"gitleaks","rule":"github-pat","file":"cfg.txt","line":1}],"historical_findings":[]}' \
    > "$PROJECT/audits/current.json"
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  DIFF_ARGS=(--baseline=audits/current.json)
  run_diff_at "$PROJECT" "$BIN"
  assert_blocked_by "gitleaks/github-pat"
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "R3: merge mode: a change to the explicit --baseline needs approval" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' > "$PROJECT/audits/current.json"
  commit_all "base explicit baseline"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[],"note":"x"}' > "$PROJECT/audits/current.json"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge --baseline=audits/current.json)
  run_diff_at "$PROJECT" "$BIN" SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
}

@test "R3: an explicit --baseline absent from the base BLOCKS" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' > "$PROJECT/audits/new.json"
  change_ts
  commit_all
  DIFF_ARGS=(--baseline=audits/new.json)
  run_diff_at "$PROJECT" "$BIN" SEMGREP_MODE=clean
  assert_blocked_by "no baseline JSON found"
}

@test "R3: an explicit --baseline outside the repository is refused" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' > "$TEST_ROOT/outside.json"
  change_ts
  commit_all
  DIFF_ARGS=("--baseline=$TEST_ROOT/outside.json")
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "--baseline must name a file in the repository"
}

# R4: the function purge cannot itself be intercepted.
FORGED='() { printf "\nOverall: MERGEABLE\n\n"; exit 0; }'

@test "R4: an exported builtin function cannot forge a verdict" {
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff "BASH_FUNC_builtin%%=$FORGED"
  assert_blocked_by "gitleaks/github-pat"
}

@test "R4: exported builtin, unset, set, command, type and compgen functions together cannot forge a verdict" {
  printf 'token = "%s"\n' "$TOKEN" > "$PROJECT/cfg.txt"
  commit_all
  run_diff "BASH_FUNC_builtin%%=$FORGED" "BASH_FUNC_unset%%=$FORGED" "BASH_FUNC_set%%=$FORGED" \
    "BASH_FUNC_command%%=$FORGED" "BASH_FUNC_type%%=$FORGED" "BASH_FUNC_compgen%%=$FORGED"
  assert_blocked_by "gitleaks/github-pat"
}

# R5: canonicalization does not trust a PATH readlink; git is vetted before use.
@test "R5: a readlink linked into the project cannot vouch for an engine" {
  fake_project_semgrep
  printf '#!/usr/bin/env bash\necho /usr/bin/true\n' > "$PROJECT/.tools/readlink"
  chmod +x "$PROJECT/.tools/readlink"
  mkdir -p "$TEST_ROOT/linkbin"
  ln -s "$PROJECT/.tools/readlink" "$TEST_ROOT/linkbin/readlink"
  ln -s "$PROJECT/.tools/semgrep" "$TEST_ROOT/linkbin/semgrep"
  change_ts
  commit_all
  run_diff_at "$TEST_ROOT" "$TEST_ROOT/linkbin:$BIN"
  assert_blocked_by "semgrep resolves inside the scanned project"
  [ ! -e "$TEST_ROOT/pwned" ]
}

@test "R5: a git linked into the project is refused before it ever runs" {
  real_git="$(readlink "$BIN/git")"
  mkdir -p "$PROJECT/.tools" "$TEST_ROOT/linkbin"
  printf '#!/usr/bin/env bash\n: > "%s/pwned"\nexec "%s" "$@"\n' "$TEST_ROOT" "$real_git" > "$PROJECT/.tools/git"
  chmod +x "$PROJECT/.tools/git"
  ln -s "$PROJECT/.tools/git" "$TEST_ROOT/linkbin/git"
  change_ts
  commit_all
  run_diff_at "$TEST_ROOT" "$TEST_ROOT/linkbin:$BIN"
  assert_blocked_by "git resolves inside the scanned project"
  [ ! -e "$TEST_ROOT/pwned" ]
}

# R7: a push that targets main cannot change gate config, approved or not.
@test "R7: --target=main BLOCKS a gate-config change even with an owner-approved PR" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" release owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge --target=main)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "cannot change gate config, approved or not"
}

@test "R7: the process-gate adapter passes --target=main through" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" release owner "gate-config-approved: $(head_sha)"
  run env PATH="$BIN" CODEX_PROJECT_DIR="$PROJECT" CLAUDE_PROJECT_DIR="$PROJECT" \
    SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    SEMGREP_MODE=clean PG_MODE=merge \
    bash "$SCRIPT_ROOT/../process-gate/scripts/check-security-diff.sh" --range=HEAD~1..HEAD --target=main
  assert_blocked_by "cannot change gate config, approved or not"
}

@test "R7 CONTROL: without --target=main the owner-approved PR still proceeds" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" release owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
}

# --- B0-6 loader paths, at any depth (pi can start in a subdirectory) ------

assert_loader_path_notice() {
  mkdir -p "$PROJECT/$(dirname "$1")"
  printf 'x\n' > "$PROJECT/$1"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" == *"$1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$(push_notice "$(head_sha)")"* ]] || { echo "$output"; false; }
}

@test "loader path: nested sub/.pi/x is gate config" {
  assert_loader_path_notice sub/.pi/x
}

@test "loader path: nested sub/.agents/skills/y/SKILL.md is gate config" {
  assert_loader_path_notice sub/.agents/skills/y/SKILL.md
}

@test "loader path: nested pkg/.agents/agents/a.md is gate config" {
  assert_loader_path_notice pkg/.agents/agents/a.md
}

@test "loader path: .agents/workflows/w.yml is gate config" {
  assert_loader_path_notice .agents/workflows/w.yml
}

@test "loader path: .trellis/state.json is gate config" {
  assert_loader_path_notice .trellis/state.json
}

@test "loader path: merge mode BLOCKS a nested sub/.pi change without approval" {
  mkdir -p "$PROJECT/sub/.pi"
  printf 'x\n' > "$PROJECT/sub/.pi/x"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
}

# --- approval branches: each refusal names its own reason ------------------

@test "merge mode: a repo view with no owner login fails closed" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_OWNER=
  assert_blocked_by "gh returned no repository owner"
}

@test "merge mode: a PR that cannot be read after selection fails closed" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_VIEW_MODE=fail
  assert_blocked_by "gh could not read PR #7"
}

@test "merge mode: a PR no longer open at the head when read is BLOCKED" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  sed 's/"state":"OPEN"/"state":"CLOSED"/' "$TEST_ROOT/gh-pr-7.json" > "$TEST_ROOT/gh-view-7.json"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "PR #7 is not open at head"
}

# --- B0-6 follow-on: env files, any depth, case-insensitive ----------------
# Matched on the path only; the gate never reads an .env* file's contents.

@test "env path: nested sub/.envrc is gate config" {
  assert_loader_path_notice sub/.envrc
}

@test "env path: root .env.local is gate config" {
  assert_loader_path_notice .env.local
}

@test "env path: merge mode BLOCKS a nested sub/.envrc change without approval" {
  mkdir -p "$PROJECT/sub"
  printf 'x\n' > "$PROJECT/sub/.envrc"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "has no 'gate-config-approved:"
}

@test "case-insensitive: an upper-case .PI/x is gate config" {
  assert_loader_path_notice .PI/x
}

@test "case-insensitive: an upper-case SUB/.AGENTS/SKILLS/y is gate config" {
  assert_loader_path_notice SUB/.AGENTS/SKILLS/y
}

# --- B0-7 parity with process-gate's approval predicate --------------------

@test "parity: a full page of open PRs (1000) is refused as possibly truncated" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  python3 - "$TEST_ROOT/gh-list.json" "$(head_sha)" <<'PY'
import json, sys
prs = [{"number": 7, "state": "OPEN", "headRefOid": sys.argv[2], "baseRefName": "main"}]
prs += [{"number": 1000 + i, "state": "OPEN", "headRefOid": "0" * 40, "baseRefName": "main"} for i in range(999)]
json.dump(prs, open(sys.argv[1], "w"))
PY
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "may be truncated"
}

@test "parity: a full page of PR comments (100) is refused as possibly truncated" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  python3 - "$TEST_ROOT/gh-pr-7.json" <<'PY'
import json, sys
pr = json.load(open(sys.argv[1]))
pr["comments"] += [{"author": {"login": "someone"}, "body": "noise"} for _ in range(99)]
json.dump(pr, open(sys.argv[1], "w"))
PY
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "may be truncated"
}

@test "parity: a CRLF-terminated owner approval line is accepted" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)\\r\\nthanks"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_mergeable
}

@test "parity: an upper-case SHA in the approval line does not match" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha | tr 'a-f' 'A-F')"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "security config changed: needs human review"
}

@test "parity: the owner login must match exactly, not case-insensitively" {
  write_config 'SECURITY_GATE_SHELLCHECK="1"'
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main Owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean GH_OWNER=owner
  assert_blocked_by "security config changed: needs human review"
}

@test "parity: .claude/skills/process-gate-local/** is gate config" {
  assert_loader_path_notice .claude/skills/process-gate-local/local.config.sh
}

@test "parity: the deprecated .claude/skills/process-gate/local.config.sh is gate config" {
  assert_loader_path_notice .claude/skills/process-gate/local.config.sh
}

@test "parity: a nested secrets-allowlist.txt is gate config" {
  assert_loader_path_notice sub/secrets-allowlist.txt
}

@test "parity: .agents/skills/process-gate-local/** is gate config" {
  assert_loader_path_notice .agents/skills/process-gate-local/local.config.sh
}

# --- BGSEC-C: Unicode aliases of gate-config paths --------------------------
# APFS/HFS+ fold case and compatibility forms: `.agents/ſkills` (U+017F, long
# s) checks out as `.agents/skills`. Paths are matched after NFKC + full case
# folding, which bash nocasematch alone does not do.

@test "BGSEC-C: a long-s .agents/ſkills/evil/SKILL.md is gate config" {
  assert_loader_path_notice ".agents/ſkills/evil/SKILL.md"
}

@test "BGSEC-C: a fullwidth sub/.ｐｉ/x is gate config" {
  assert_loader_path_notice "sub/.ｐｉ/x"
}

@test "BGSEC-C: a Kelvin-sign .agents/sKills/x is gate config" {
  assert_loader_path_notice ".agents/s"$'\xe2\x84\xaa'"ills/x"
}

@test "BGSEC-C: a long-s .trelliſ/runtime is gate config" {
  assert_loader_path_notice ".trelliſ/runtime"
}

@test "BGSEC-C: merge mode BLOCKS a long-s .agents/ſkills change without approval" {
  mkdir -p "$PROJECT/.agents/ſkills/evil"
  printf 'x\n' > "$PROJECT/.agents/ſkills/evil/SKILL.md"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "has no 'gate-config-approved:"
}

# --- BGSEC-A: .trellis.json steers the diff base ----------------------------

@test "BGSEC-A: .trellis.json is gate config" {
  assert_loader_path_notice .trellis.json
}

# --- BGSEC-B: run directly with --target=main, every gate-config change is refused

@test "BGSEC-B: --target=main refuses a baseline change under a custom SECURITY_GATE_AUDIT_DIR" {
  write_config 'SECURITY_GATE_AUDIT_DIR="sec/audits"'
  mkdir -p "$PROJECT/sec/audits"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/sec/audits/2026-01-01-baseline-project.json"
  commit_all "base custom audit dir"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[],"n":1}' \
    > "$PROJECT/sec/audits/2026-01-01-baseline-project.json"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge --target=main)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "cannot change gate config, approved or not"
  [[ "$output" == *"sec/audits/2026-01-01-baseline-project.json"* ]] || { echo "$output"; false; }
}

@test "BGSEC-B: --target=main refuses a change to an explicit --baseline" {
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' > "$PROJECT/audits/current.json"
  commit_all "base explicit baseline"
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[],"n":1}' > "$PROJECT/audits/current.json"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge --target=main --baseline=audits/current.json)
  run_diff_at "$PROJECT" "$BIN" SEMGREP_MODE=clean
  assert_blocked_by "cannot change gate config, approved or not"
}

# --- BGSEC-C: look-alikes NFKC does not map ---------------------------------
# NFKC leaves Cyrillic as Cyrillic, so a conservative rule sits on top: a
# non-ASCII character in a dot-prefixed segment, or in the segment directly
# under one, makes the path gate config.

@test "BGSEC-C: a Cyrillic-a .аgents/skills/x is gate config" {
  assert_loader_path_notice ".аgents/skills/x"
}

@test "BGSEC-C: a Cyrillic-er .рi/x is gate config" {
  assert_loader_path_notice ".рi/x"
}

@test "BGSEC-C: a Cyrillic letter in the segment under a dot segment is gate config" {
  assert_loader_path_notice ".agents/ѕkills/x"
}

@test "BGSEC-C: merge mode BLOCKS a Cyrillic .рi change without approval" {
  mkdir -p "$PROJECT/.рi"
  printf 'x\n' > "$PROJECT/.рi/x"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "has no 'gate-config-approved:"
}

@test "BGSEC-C: --target=main refuses a Cyrillic .аgents change, approved or not" {
  mkdir -p "$PROJECT/.аgents/skills"
  printf 'x\n' > "$PROJECT/.аgents/skills/x"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge --target=main)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "cannot change gate config, approved or not"
}

@test "non-ASCII rule: a non-ASCII path outside any dot segment (docs/café.md) is gate config" {
  assert_loader_path_notice "docs/café.md"
}

@test "BGSEC-C: a fullwidth full stop sub/．pi/x is gate config (only folding catches it)" {
  assert_loader_path_notice "sub/．pi/x"
}

# --- finding #25: the look-alike rule on raw AND folded segments, Cf-stripped
# A dot-like leader (U+2024, U+FE52) folds to "."; an invisible format
# character (Unicode Cf: U+200B, U+FEFF) before the dot survives NFKC and
# hides it from startswith("."). Each test below is caught by exactly the
# check its title names, so dropping that check turns it red.

@test "#25: a ONE DOT LEADER U+2024pi/x is gate config" {
  assert_loader_path_notice $'\xe2\x80\xa4'"pi/x"
}

@test "#25: a SMALL FULL STOP U+FE52pi/x is gate config" {
  assert_loader_path_notice $'\xef\xb9\x92'"pi/x"
}

@test "#25: a ZERO WIDTH SPACE before .pi (U+200B.pi/x) is gate config (Cf strip)" {
  assert_loader_path_notice $'\xe2\x80\x8b'".pi/x"
}

@test "#25: a BOM before .agents (U+FEFF.agents/skills/x) is gate config (Cf strip)" {
  assert_loader_path_notice $'\xef\xbb\xbf'".agents/skills/x"
}

@test "#25: a ligature in a dot segment (.conﬁg/x) is gate config (raw-side check)" {
  assert_loader_path_notice ".conﬁg/x"
}

@test "#25: a fullwidth stop before Cyrillic (．рi/x) is gate config (folded-side check)" {
  assert_loader_path_notice "．рi/x"
}

# --- finding #27: .trellis.json and .trellis/ at any depth ------------------
# A subproject's .trellis.json, or a checkout started below the root, steers
# resolution as well.

@test "#27: a nested sub/.trellis.json is gate config" {
  assert_loader_path_notice sub/.trellis.json
}

@test "#27: a nested sub/.trellis/state.json is gate config" {
  assert_loader_path_notice sub/.trellis/state.json
}

@test "#27: an upper-case .TRELLIS.json is gate config" {
  assert_loader_path_notice .TRELLIS.json
}

@test "#27: a fullwidth-dot sub/．trellis.json is gate config" {
  assert_loader_path_notice "sub/．trellis.json"
}

# --- release-owner ruling: ANY non-ASCII byte in a changed path is gate config
# (replaces the dot-segment and Cf heuristics; non-ASCII names are rare here).

@test "non-ASCII rule: a variation selector before the dot (U+FE0F.pi/x) is gate config" {
  assert_loader_path_notice $'\xef\xb8\x8f'".pi/x"
}

@test "non-ASCII rule: a combining acute before the dot (U+0301.pi/x) is gate config" {
  assert_loader_path_notice $'\xcc\x81'".pi/x"
}

@test "non-ASCII rule: a Hangul filler before the dot (U+3164.pi/x) is gate config" {
  assert_loader_path_notice $'\xe3\x85\xa4'".pi/x"
}

@test "non-ASCII rule: merge mode BLOCKS a U+3164.pi change without approval" {
  mkdir -p "$PROJECT/"$'\xe3\x85\xa4'".pi"
  printf 'x\n' > "$PROJECT/"$'\xe3\x85\xa4'".pi/x"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main
  DIFF_ARGS=(--mode=merge)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "has no 'gate-config-approved:"
}

@test "non-ASCII rule: --target=main refuses a non-ASCII path, approved or not" {
  mkdir -p "$PROJECT/docs"
  printf 'x\n' > "$PROJECT/docs/café.md"
  change_ts
  commit_all
  add_pr 7 OPEN "$(head_sha)" main owner "gate-config-approved: $(head_sha)"
  DIFF_ARGS=(--mode=merge --target=main)
  run_diff SEMGREP_MODE=clean
  assert_blocked_by "cannot change gate config, approved or not"
}

@test "non-ASCII rule CONTROL: an ASCII path outside the protected set is not gate config" {
  mkdir -p "$PROJECT/docs"
  printf 'x\n' > "$PROJECT/docs/cafe.md"
  change_ts
  commit_all
  run_diff SEMGREP_MODE=clean
  assert_mergeable
  [[ "$output" != *"security config changed"* ]] || { echo "$output"; false; }
}
