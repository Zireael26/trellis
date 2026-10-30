#!/usr/bin/env bats
# Diff-mode Gitleaks must use the native config copied from the range base,
# never the candidate or worktree config. The fixture scanner honors --config.

setup() {
  TEST_ROOT="$BATS_TEST_TMPDIR"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  SCRIPT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$PROJECT/audits" "$BIN"
  unset CODEX_PROJECT_DIR CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

  export GITLEAKS_EFFECTIVE_CONFIG="$TEST_ROOT/effective-config.toml"
  export GITLEAKS_CONFIG_ARG="$TEST_ROOT/config-arg"
  export GITLEAKS_TEST_PROJECT="$PROJECT"
  TOKEN="ghp_$(printf '%s' 0123456789abcdefghij ABCDEFGHIJ 012345)"
  export GITLEAKS_TOKEN="$TOKEN"

  git -C "$PROJECT" init -q
  git -C "$PROJECT" config user.email security-gate@trellis.test
  git -C "$PROJECT" config user.name 'trellis test'
  printf '%s\n' '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}' \
    > "$PROJECT/audits/2026-01-01-baseline-project.json"
  cat > "$PROJECT/.gitleaks.toml" <<'TOML'
[allowlist]
description = "Known SHA-256 pin false positive"
paths = ["^sha256-pins\\.txt$"]
TOML
  cp "$PROJECT/.gitleaks.toml" "$TEST_ROOT/base-config.expected"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm seed

  cat > "$BIN/gitleaks" <<'SH'
#!/usr/bin/env bash
source_dir="" range="" config="" report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    --log-opts=*) range="${1#--log-opts=}"; shift ;;
    --report-path) report="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$config" > "$GITLEAKS_CONFIG_ARG"
# Red-test-only mode: emulate a CLI/config-discovery failure and prove the
# candidate worktree policy cannot satisfy this regression's assertions.
if [ "${GITLEAKS_TEST_MODE:-}" = worktree ]; then config=""; fi
[ -n "$config" ] || config="$GITLEAKS_TEST_PROJECT/.gitleaks.toml"
cp "$config" "$GITLEAKS_EFFECTIVE_CONFIG"
patch="$(git -C "$source_dir" log -p "$range" 2>/dev/null)" || exit 2
allow_sha=0 allow_secret=0 allow_all=0
if grep -Fq 'paths = ["^sha256-pins\\.txt$"]' "$config"; then allow_sha=1; fi
if grep -Fq 'paths = ["^secret\\.txt$"]' "$config"; then allow_secret=1; fi
if grep -Fq 'paths = [".*"]' "$config"; then allow_all=1; fi
findings=()
if grep -Fq '+sha256-pin: ' <<<"$patch" && [ "$allow_sha" -eq 0 ] && [ "$allow_all" -eq 0 ]; then
  findings+=("{\"RuleID\":\"sha256-pin-fp\",\"Description\":\"SHA-256 pin false positive\",\"File\":\"sha256-pins.txt\",\"StartLine\":1}")
fi
if grep -Fq "+token=$GITLEAKS_TOKEN" <<<"$patch" && [ "$allow_secret" -eq 0 ] && [ "$allow_all" -eq 0 ]; then
  findings+=("{\"RuleID\":\"github-pat\",\"Description\":\"GitHub PAT\",\"File\":\"secret.txt\",\"StartLine\":1,\"Commit\":\"abc12345\"}")
fi
printf '[' > "$report"
sep=""
for finding in "${findings[@]}"; do printf '%s%s' "$sep" "$finding" >> "$report"; sep=,; done
printf ']\n' >> "$report"
[ "${#findings[@]}" -eq 0 ] && exit 0
exit 1
SH
  chmod +x "$BIN/gitleaks"
}

commit_all() {
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "${1:-change}"
}

run_diff() {
  run env PATH="$BIN:$PATH" SECURITY_GATE_STACK_PROFILE=web-next SECURITY_GATE_PROJECT_NAME=project \
    GITLEAKS_TEST_PROJECT="$PROJECT" GITLEAKS_TOKEN="$TOKEN" \
    GITLEAKS_EFFECTIVE_CONFIG="$GITLEAKS_EFFECTIVE_CONFIG" GITLEAKS_CONFIG_ARG="$GITLEAKS_CONFIG_ARG" \
    bash "$SCRIPT_ROOT/scripts/run-diff.sh" "$PROJECT" --range=HEAD~1..HEAD --no-llm
}

@test "diff Gitleaks uses only the base native allowlist for SHA-256 pins" {
  printf '%s\n' '[allowlist]' 'description = "untrusted candidate allow-all"' 'paths = [".*"]' \
    > "$PROJECT/.gitleaks.toml"
  printf '%s\n' "sha256-pin: $(printf '%064d' 0 | tr 0 a)" > "$PROJECT/sha256-pins.txt"
  printf 'token=%s\n' "$TOKEN" > "$PROJECT/secret.txt"
  commit_all candidate
  # Uncommitted worktree config is distinct from both BASE and HEAD.
  printf '%s\n' '[allowlist]' 'description = "untrusted worktree secret allowlist"' \
    'paths = ["^secret\\.txt$"]' > "$PROJECT/.gitleaks.toml"

  run_diff
  [ "$status" -eq 1 ] || { echo "rc=$status; $output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gitleaks/github-pat"* ]] || { echo "$output"; false; }
  [[ "$output" != *"gitleaks/sha256-pin-fp"* ]] || { echo "$output"; false; }
  [ "$(cat "$GITLEAKS_CONFIG_ARG")" != "$PROJECT/.gitleaks.toml" ]
  cmp -s "$TEST_ROOT/base-config.expected" "$GITLEAKS_EFFECTIVE_CONFIG"
}
