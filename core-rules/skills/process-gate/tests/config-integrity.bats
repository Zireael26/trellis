#!/usr/bin/env bats
# Gate-config integrity (B0-4): a range cannot weaken the gate that judges it.
#   - local.config.sh, stack validators and secrets-allowlist.txt load from the
#     range BASE, never the working tree or the range's own head.
#   - local.config.sh is parsed as DATA; anything else is BLOCKED `not data`.
#   - A range that changes gate config prints a notice at push and is BLOCKED
#     at merge without the owner's approval (config-approval.bats).
#   - Present-but-unsupported base config BLOCKS; paths are read NUL-delimited.
#   - A passing run-all rc needs exactly one matching Overall line at pre-push.
# Validators and their dependencies: config-validators.bats. Fixture:
# config-fixture.bash.

load config-fixture

setup() {
  config_fixture_setup
}

@test "a range adding an exit-0 local.config.sh never passes without a verdict" {
  use_real check-secrets.sh
  feature
  put "$CFG" $'exit 0\n'
  put creds.txt "aws_key = \"AKIA""IOSFODNN7EXAMPLE\""$'\n'
  commit_all 'add exit-0 config and a key' || return 1
  local head
  head="$(head_sha)"

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Secrets:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate config changed in range: gated with BASE config; merge requires gate-config-approved: $head"* ]] || { echo "$output"; false; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"merge requires gate-config-approved: $head from the repo owner on the PR"* ]] || { echo "$output"; false; }
}

@test "a range setting PROCESS_GATE_TEST_CMD=true is gated with the base test command" {
  use_real check-tests.sh
  put "$CFG" $'PROCESS_GATE_TYPECHECK_CMD="true"\nPROCESS_GATE_LINT_CMD="true"\nPROCESS_GATE_TEST_CMD="false"\n'
  commit_all 'base config' || return 1
  feature
  put "$CFG" $'PROCESS_GATE_TYPECHECK_CMD="true"\nPROCESS_GATE_LINT_CMD="true"\nPROCESS_GATE_TEST_CMD=true\n'
  commit_all 'weaken the test command' || return 1
  local head
  head="$(head_sha)"

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Tests & coverage:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *'tests: `false` exited 1'* ]] || { echo "$output"; false; }
  [[ "$output" == *"gate config changed in range: gated with BASE config; merge requires gate-config-approved: $head"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: $CFG"* ]] || { echo "$output"; false; }
  [ ! -e "$GH_LOG" ] || { echo "push mode asked gh"; cat "$GH_LOG"; false; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"merge requires gate-config-approved: $head from the repo owner on the PR; no single open PR has head $head"* ]] || { echo "$output"; false; }
}

@test "a base local.config.sh with a function is BLOCKED as not data" {
  put "$CFG" $'PROCESS_GATE_STACK_PROFILE="n-a"\npg_log() { :; }\n'
  commit_all 'base config with code' || return 1
  local mode
  for mode in push merge; do
    run_gate "$mode"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"process-gate local config is not data: $CFG:2: pg_log() { :; }"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
    [[ "$output" != *"[stub:"* ]] || { echo "$output"; false; }
  done
}

@test "nested expansion, command substitution and ; in a config value are not data" {
  local value
  for value in '"${PROCESS_GATE_TEST_TIMEOUT:-$(id)}"' '"${PROCESS_GATE_TEST_TIMEOUT:-${HOME}}"' \
    '"${PROCESS_GATE_TEST_TIMEOUT:-`id`}"' '"$(id)"' "'\$(id)'" '"${HOME}"' '"a;b"' "'a;b'" \
    '"${PROCESS_GATE_OTHER:-1}"'; do
    git -C "$PROJECT_DIR" checkout -q main
    put "$CFG" "PROCESS_GATE_TEST_TIMEOUT=$value"$'\n'
    commit_all "config $value" || return 1
    run_gate push
    [ "$status" -eq 1 ] || { echo "$value"; echo "$output"; false; }
    [[ "$output" == *"process-gate local config is not data: $CFG:1: PROCESS_GATE_TEST_TIMEOUT=$value"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  done
}

@test "export and source lines in a config are not data" {
  local line
  for line in 'export PROCESS_GATE_X=1' 'source foo'; do
    git -C "$PROJECT_DIR" checkout -q main
    put "$CFG" "$line"$'\n'
    commit_all "config $line" || return 1
    run_gate push
    [ "$status" -eq 1 ] || { echo "$line"; echo "$output"; false; }
    [[ "$output" == *"process-gate local config is not data: $CFG:1: $line"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  done
}

@test "a base DATA config is honoured in every documented form" {
  local probe="$BATS_TEST_TMPDIR/probe.txt" marker="$BATS_TEST_TMPDIR/validator.txt"
  cat > "$STUB/scripts/check-docs.sh" <<SH
#!/usr/bin/env bash
SKILL_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
. "\$SKILL_DIR/scripts/lib/common.sh"
pg_load_config "\$@" || exit 1
{
  printf 'size=%s\n' "\${PROCESS_GATE_PR_SIZE_LIMIT:-}"
  printf 'timeout=%s\n' "\${PROCESS_GATE_TEST_TIMEOUT:-}"
  printf 'lint=%s\n' "\${PROCESS_GATE_LINT_CMD:-}"
  printf 'trigger=%s\n' "\${PROCESS_GATE_ADR_TRIGGERS[@]}"
} > '$probe'
SH
  put "$CFG" "# shellcheck shell=bash
# comment line

PROCESS_GATE_STACK_PROFILE=\"custom\"
PROCESS_GATE_PR_SIZE_LIMIT=900   # trailing comment
PROCESS_GATE_LINT_CMD='ruff check && bash scripts/lint.sh'
PROCESS_GATE_TEST_TIMEOUT=\"\${PROCESS_GATE_TEST_TIMEOUT:-7260}\"
PROCESS_GATE_ADR_TRIGGERS=( \"src/\" lib/ )
PROCESS_GATE_STACK_VALIDATORS=(
  \"stack-check.sh\"
)
"
  put .claude/skills/process-gate-local/stack-check.sh "printf invoked > '$marker'"$'\n'
  commit_all 'base data config' || return 1

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: MERGEABLE"* ]] || { echo "$output"; false; }
  [[ "$output" != *"not data"* ]] || { echo "$output"; false; }
  [ "$(cat "$marker")" = invoked ]
  [ "$(cat "$probe")" = $'size=900\ntimeout=7260\nlint=ruff check && bash scripts/lint.sh\ntrigger=src/\ntrigger=lib/' ] || { cat "$probe"; false; }

  run bash -c "cd '$PROJECT_DIR' && PROCESS_GATE_TEST_TIMEOUT=5460 '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'timeout=5460' "$probe" || { cat "$probe"; false; }
}

@test "a range allowlisting its own secret still fails Secrets" {
  use_real check-secrets.sh
  feature
  put .claude/skills/process-gate-local/secrets-allowlist.txt 'docs/api.md:sk_''live_[A-Za-z0-9]{24,}'$'\n'
  put docs/api.md "sk_""live_abcdefghijklmnopqrstuvwx"$'\n'
  commit_all 'allowlist own secret' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Secrets:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"docs/api.md:1 — Stripe live key"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: .claude/skills/process-gate-local/secrets-allowlist.txt"* ]] || { echo "$output"; false; }
}

@test "a range replacing a stack validator with exit 0 runs the base validator" {
  put "$CFG" $'PROCESS_GATE_STACK_PROFILE="custom"\nPROCESS_GATE_STACK_VALIDATORS=("stack-check.sh")\n'
  put .claude/skills/process-gate-local/stack-check.sh $'echo BASE-VALIDATOR-RAN\nexit 1\n'
  commit_all 'base validator' || return 1
  feature
  put .claude/skills/process-gate-local/stack-check.sh $'echo HEAD-VALIDATOR-RAN\nexit 0\n'
  commit_all 'neuter validator' || return 1

  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Stack profile:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"BASE-VALIDATOR-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" != *"HEAD-VALIDATOR-RAN"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: .claude/skills/process-gate-local/stack-check.sh"* ]] || { echo "$output"; false; }
}

@test "a range deleting local.config.sh is a gate-config change" {
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=900\n'
  commit_all 'base config' || return 1
  feature
  git -C "$PROJECT_DIR" rm -q "$CFG"
  commit_all 'drop the config' || return 1
  local head
  head="$(head_sha)"

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gate config changed in range: gated with BASE config; merge requires gate-config-approved: $head"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: $CFG"* ]] || { echo "$output"; false; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  [[ "$output" == *"merge requires gate-config-approved: $head from the repo owner on the PR; no single open PR has head $head"* ]] || { echo "$output"; false; }
}

@test "empty array items are kept" {
  probe_row PROCESS_GATE_ADR_TRIGGERS PROCESS_GATE_CHANGELOG_PATHS
  put "$CFG" $'PROCESS_GATE_ADR_TRIGGERS=("a" "")\nPROCESS_GATE_CHANGELOG_PATHS=(\n  ""\n  "b"\n  \'\'\n)\n'
  commit_all 'arrays with empty items' || return 1
  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$PROBE")" = $'PROCESS_GATE_ADR_TRIGGERS#=2\nPROCESS_GATE_ADR_TRIGGERS=a\nPROCESS_GATE_ADR_TRIGGERS=\nPROCESS_GATE_CHANGELOG_PATHS#=3\nPROCESS_GATE_CHANGELOG_PATHS=\nPROCESS_GATE_CHANGELOG_PATHS=b\nPROCESS_GATE_CHANGELOG_PATHS=' ] ||
    { cat "$PROBE"; false; }
}

@test "twin precedence: the active harness's config wins; deprecated only without twins" {
  probe_row PROCESS_GATE_PR_SIZE_LIMIT
  put .agents/skills/process-gate-local/local.config.sh $'PROCESS_GATE_PR_SIZE_LIMIT=111\n'
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=222\n'
  put .claude/skills/process-gate/local.config.sh $'PROCESS_GATE_PR_SIZE_LIMIT=333\n'
  commit_all 'twins and deprecated' || return 1

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'PROCESS_GATE_PR_SIZE_LIMIT=222' "$PROBE" || { cat "$PROBE"; false; }

  run bash -c "cd '$PROJECT_DIR' && CODEX_PROJECT_DIR='$PROJECT_DIR' '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'PROCESS_GATE_PR_SIZE_LIMIT=111' "$PROBE" || { cat "$PROBE"; false; }

  git -C "$PROJECT_DIR" rm -q .agents/skills/process-gate-local/local.config.sh "$CFG"
  commit_all 'only the deprecated config' || return 1
  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'PROCESS_GATE_PR_SIZE_LIMIT=333' "$PROBE" || { cat "$PROBE"; false; }
}

@test "a three-dot range loads config from the merge-base, not either tip" {
  probe_row PROCESS_GATE_PR_SIZE_LIMIT
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=111\n'
  commit_all 'fork point config' || return 1
  feature
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=333\n'
  commit_all 'feature changes the config' || return 1
  git -C "$PROJECT_DIR" switch -q main
  put "$CFG" $'PROCESS_GATE_PR_SIZE_LIMIT=222\n'
  commit_all 'main moves on' || return 1
  git -C "$PROJECT_DIR" switch -q feature

  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=main...feature"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'PROCESS_GATE_PR_SIZE_LIMIT=111' "$PROBE" || { cat "$PROBE"; false; }
  [[ "$output" == *"changed: $CFG"* ]] || { echo "$output"; false; }
}

@test "a base local.config.sh that is a symlink is BLOCKED in either twin" {
  local twin
  for twin in .claude .agents; do
    git -C "$PROJECT_DIR" checkout -q main
    git -C "$PROJECT_DIR" checkout -q -B "case-${twin#.}"
    put cfg-data.sh $'PROCESS_GATE_TEST_CMD="false"\n'
    mkdir -p "$PROJECT_DIR/$twin/skills/process-gate-local"
    ln -s ../../../cfg-data.sh "$PROJECT_DIR/$twin/skills/process-gate-local/local.config.sh"
    commit_all "symlinked $twin config" || return 1
    run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=HEAD"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *"process-gate local config $twin/skills/process-gate-local/local.config.sh at range base"*"is not a regular file"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
  done
}

@test "an unsupported active config never falls back to the deprecated one" {
  put .claude/skills/process-gate/local.config.sh $'PROCESS_GATE_PR_SIZE_LIMIT=333\n'
  mkdir -p "$PROJECT_DIR/$CFG"
  put "$CFG/inner.txt" $'not a config\n'
  commit_all 'config path is a tree' || return 1
  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate local config $CFG at range base"*"is not a regular file"* ]] || { echo "$output"; false; }
  [[ "$output" != *"[stub:"* ]] || { echo "$output"; false; }
}

@test "a symlinked process-gate-local directory at the base is BLOCKED" {
  put elsewhere/local.config.sh $'PROCESS_GATE_TEST_CMD="false"\n'
  mkdir -p "$PROJECT_DIR/.claude/skills"
  ln -s ../../elsewhere "$PROJECT_DIR/.claude/skills/process-gate-local"
  commit_all 'symlinked config dir' || return 1
  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate local config dir .claude/skills/process-gate-local at range base"*"is not a directory"* ]] || { echo "$output"; false; }
}

@test "a base secrets allowlist that is a symlink fails Secrets" {
  use_real check-secrets.sh
  put allow-data.txt $'docs/api.md:sk_''live_[A-Za-z0-9]{24,}\n'
  mkdir -p "$PROJECT_DIR/.claude/skills/process-gate-local"
  ln -s ../../../allow-data.txt "$PROJECT_DIR/.claude/skills/process-gate-local/secrets-allowlist.txt"
  commit_all 'symlinked allowlist' || return 1
  feature
  put notes.txt $'clean change\n'
  commit_all 'clean change' || return 1
  run_gate push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Secrets:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"allowlist .claude/skills/process-gate-local/secrets-allowlist.txt at the range base is not a regular file"* ]] || { echo "$output"; false; }
}

@test "every row refuses a missing range base (Analyze with rc 2)" {
  local row want
  for row in check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh check-docs.sh \
    check-security-diff.sh check-analyze.sh check-slop.sh; do
    want=1
    # check-tests.sh runs the full battery (notice) instead of failing closed
    # on an unresolvable base, like Analyze with rc 2.
    [ "$row" != check-analyze.sh ] && [ "$row" != check-tests.sh ] || want=2
    run bash -c "cd '$PROJECT_DIR' && bash '$REAL_SCRIPTS/$row' --range=missing-base..HEAD"
    [ "$status" -eq "$want" ] || { echo "$row rc=$status"; echo "$output"; false; }
    [[ "$output" == *"process-gate cannot resolve the base of range missing-base..HEAD"* ]] || { echo "$row"; echo "$output"; false; }
  done
}

# Names Git would quote in its default output: Unicode, quotes, tab, newline.
odd_names() {
  printf '%s\0' "chéck.sh" "q\"uote'.sh" "$(printf 't\tab.sh')" "$(printf 'n\nl.sh')"
}

@test "added gate-config files with unusual names are detected in both twins" {
  local twin name
  for twin in .claude .agents; do
    while IFS= read -r -d '' name; do
      git -C "$PROJECT_DIR" checkout -q -B feature main
      put "$twin/skills/process-gate-local/$name" $'echo helper\n'
      commit_all "add $twin $name" || return 1
      run_gate push
      [ "$status" -eq 0 ] || { echo "$output"; false; }
      [[ "$output" == *"gate config changed in range"* ]] || { printf '%s %q\n' "$twin" "$name"; echo "$output"; false; }
      [[ "$output" == *"changed: "*"$twin/skills/process-gate-local/"* ]] || { echo "$output"; false; }
    done < <(odd_names)
  done
}

@test "deleting or renaming an unusually named gate-config file is detected" {
  put ".agents/skills/process-gate-local/chéck.sh" $'echo helper\n'
  put ".claude/skills/process-gate-local/ré name.sh" $'echo helper\n'
  commit_all 'odd names at base' || return 1
  feature
  git -C "$PROJECT_DIR" rm -q ".agents/skills/process-gate-local/chéck.sh"
  git -C "$PROJECT_DIR" mv ".claude/skills/process-gate-local/ré name.sh" "docs/ré name.sh" 2>/dev/null ||
    { mkdir -p "$PROJECT_DIR/docs" && git -C "$PROJECT_DIR" mv ".claude/skills/process-gate-local/ré name.sh" "docs/ré name.sh"; }
  commit_all 'delete and rename' || return 1

  run_gate push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"changed: .agents/skills/process-gate-local/chéck.sh"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed: .claude/skills/process-gate-local/ré name.sh"* ]] || { echo "$output"; false; }

  run_gate merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Overall: BLOCKED"* ]] || { echo "$output"; false; }
}

@test "pre-push needs exactly one Overall line matching the rc in one verdict block" {
  prepush_fixture
  local hook
  local head='## process-gate verdict (mode=push)'
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    stub_runner 0
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    [[ "$output" == *"without exactly one 'Overall: MERGEABLE' verdict line"* ]] || { echo "$output"; false; }

    stub_runner 2
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    [[ "$output" == *"without exactly one 'Overall: NEEDS CHANGES' verdict line"* ]] || { echo "$output"; false; }

    # Contradictory or duplicated verdicts.
    stub_runner 0 "$head" 'Overall: MERGEABLE' 'Overall: BLOCKED'
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    stub_runner 0 "$head" 'Overall: MERGEABLE' "$head" 'Overall: MERGEABLE'
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    stub_runner 0 'Overall: MERGEABLE'
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    stub_runner 2 "$head" 'Overall: MERGEABLE'
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    stub_runner 0 "$head" 'Overall: NEEDS CHANGES'
    run_prepush "$hook"
    [ "$status" -ne 0 ] || { echo "$output"; false; }

    # Both rc mappings pass with their one verdict line; a nested gate's own
    # Overall under Findings is not the process-gate verdict.
    stub_runner 0 "$head" '' 'Overall: MERGEABLE'
    run_prepush "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    stub_runner 2 "$head" '' 'Overall: NEEDS CHANGES' '' '## Findings' '## security-gate verdict (diff)' 'Overall: NEEDS CHANGES'
    run_prepush "$hook"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

# ancestry_case <name> <link> <target-dir>: commit, on its own branch from
# main, a data config reachable only through the symlink <link> -> <target-dir>.
ancestry_case() {
  git -C "$PROJECT_DIR" checkout -q -B "case-$1" main
  mkdir -p "$PROJECT_DIR/$3"
  mkdir -p "$(dirname "$PROJECT_DIR/$2")"
  ln -s "$(printf '%s' "$2" | sed -e 's|[^/]*/|../|g' -e 's|[^/]*$||')$3" "$PROJECT_DIR/$2"
  commit_all "symlinked $2" || return 1
  run bash -c "cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=HEAD"
}

@test "config reached through a symlinked .claude, .agents, skills or deprecated dir is BLOCKED" {
  put real-claude/skills/process-gate-local/local.config.sh $'PROCESS_GATE_TEST_CMD="false"\n'
  put real-agents/skills/process-gate-local/local.config.sh $'PROCESS_GATE_TEST_CMD="false"\n'
  put real-skills/process-gate-local/local.config.sh $'PROCESS_GATE_TEST_CMD="false"\n'
  put real-pg/local.config.sh $'PROCESS_GATE_TEST_CMD="false"\n'
  commit_all 'backing dirs' || return 1

  ancestry_case claude .claude real-claude || return 1
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"local config dir .claude/skills/process-gate-local at range base"*"reached through a symlink"* ]] || { echo "$output"; false; }

  ancestry_case agents .agents real-agents || return 1
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"local config dir .agents/skills/process-gate-local at range base"*"reached through a symlink"* ]] || { echo "$output"; false; }

  ancestry_case skills .claude/skills real-skills || return 1
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"local config dir .claude/skills/process-gate-local at range base"*"reached through a symlink"* ]] || { echo "$output"; false; }

  ancestry_case deprecated .claude/skills/process-gate real-pg || return 1
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"local config .claude/skills/process-gate/local.config.sh at range base"*"reached through a symlink"* ]] || { echo "$output"; false; }
}

@test "an inherited BASH_ENV cannot pass the rows for run-all" {
  use_real check-secrets.sh
  # Rows see PG_MODE (run-all exports it); run-all's own startup does not.
  printf '%s\n' 'if [ -n "${PG_MODE:-}" ]; then echo "pass (startup file)"; exit 0; fi' \
    'git() { echo EVIL; }' > "$BATS_TEST_TMPDIR/evil-env.sh"
  feature
  put creds.txt "aws_key = \"AKIA""IOSFODNN7EXAMPLE\""$'\n'
  commit_all 'a key' || return 1

  run bash -c "cd '$PROJECT_DIR' && BASH_ENV='$BATS_TEST_TMPDIR/evil-env.sh' ENV='$BATS_TEST_TMPDIR/evil-env.sh' '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"Secrets:"*"fail"* ]] || { echo "$output"; false; }
  [[ "$output" != *"startup file"* ]] || { echo "$output"; false; }
}

@test "an inherited BASH_ENV printing a fake verdict cannot pass the pre-push" {
  printf '%s\n' "printf '## process-gate verdict (mode=push)\\n\\nOverall: MERGEABLE\\n'" 'exit 0' \
    > "$BATS_TEST_TMPDIR/evil-env.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/skills/process-gate-local"
  cp -R "$STUB" "$REPO/.claude/skills/process-gate"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email pre-push@test.invalid
  git -C "$REPO" config user.name pre-push-test
  git -C "$REPO" config commit.gpgsign false
  printf '/.claude/skills/process-gate/\n' > "$REPO/.git/info/exclude"
  printf 'exit 0\n' > "$REPO/$CFG"
  git -C "$REPO" add "$CFG"
  git -C "$REPO" commit -qm 'base config that is not data'
  git -C "$REPO" switch -qc feature
  OLD="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" commit --allow-empty -qm change
  NEW="$(git -C "$REPO" rev-parse HEAD)"
  printf 'refs/heads/feature %s refs/heads/feature %s\n' "$NEW" "$OLD" > "$BATS_TEST_TMPDIR/refs"

  local hook
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    run_prepush "$hook" CLAUDE_PROJECT_DIR="$REPO" BASH_ENV="$BATS_TEST_TMPDIR/evil-env.sh" ENV="$BATS_TEST_TMPDIR/evil-env.sh"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    [[ "$output" == *"process-gate local config is not data"* ]] || { echo "$output"; false; }
  done
}

@test "functions imported from the environment are dropped at run-all startup" {
  put "$CFG" $'exit 0\n'
  commit_all 'base config that is not data' || return 1
  run bash -c "printf() { echo '## process-gate verdict (mode=push)'; echo; echo 'Overall: MERGEABLE'; exit 0; }; export -f printf
    cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate local config is not data"* ]] || { echo "$output"; false; }
}

# The purge's own commands can be exported functions too: a `builtin` that
# swallows `builtin unset` and an `unset` that does nothing would leave the
# fake printf in place. The purge starts in POSIX mode, where `unset` is
# found before any function.
@test "an exported builtin or unset function cannot intercept the startup purge" {
  put "$CFG" $'exit 0\n'
  commit_all 'base config that is not data' || return 1
  run bash -c "builtin() { case \"\$1\" in unset) return 0 ;; esac; command builtin \"\$@\"; }
    unset() { return 0; }
    printf() { echo '## process-gate verdict (mode=push)'; echo; echo 'Overall: MERGEABLE'; exit 0; }
    export -f builtin unset printf
    cd '$PROJECT_DIR' && '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate local config is not data"* ]] || { echo "$output"; false; }
}

# The carriers start run-all with `bash -p`: no function arrives from the
# environment, whatever the caller exported.
@test "the pre-push carriers start run-all with no imported functions" {
  prepush_fixture
  local hook runner="$REPO/.claude/skills/process-gate/scripts/run-all.sh"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '## process-gate verdict (mode=push)\n\n'
if [ -n "$(compgen -A function)" ]; then
  compgen -A function | sed 's/^/imported: /'
  printf 'Overall: BLOCKED\n'
  exit 1
fi
printf 'Overall: MERGEABLE\n'
SH
  for hook in "$REPO_ROOT/core-rules/githooks/pre-push" "$REPO_ROOT/core-rules/husky/pre-push"; do
    run_prepush "$hook" 'BASH_FUNC_pg_probe%%=() { :; }'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" != *"imported: "* ]] || { echo "$output"; false; }
  done
}

# A startup file runs before run-all can clear anything, so direct callers
# launch it clean (SKILL.md): the clean launch gives the real verdict.
@test "a clean direct launch ignores an inherited startup file" {
  printf '%s\n' "echo '## process-gate verdict (mode=push)'; echo; echo 'Overall: MERGEABLE'; exit 0" \
    > "$BATS_TEST_TMPDIR/evil-env.sh"
  put "$CFG" $'exit 0\n'
  commit_all 'base config that is not data' || return 1
  run bash -c "cd '$PROJECT_DIR' && BASH_ENV='$BATS_TEST_TMPDIR/evil-env.sh' ENV='$BATS_TEST_TMPDIR/evil-env.sh' bash -p '$STUB/scripts/run-all.sh' --mode=push --range=main..HEAD"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"process-gate local config is not data"* ]] || { echo "$output"; false; }
}
